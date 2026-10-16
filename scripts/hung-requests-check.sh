#!/usr/bin/env bash
set -eo pipefail

# Public repo: job logs are public, so only a generic failure is printed
exec 3>&2 >/dev/null 2>&1
trap '[ $? -eq 0 ] || echo "check failed" >&3' EXIT

: "${CLOUDFLARE_OBSERVABILITY_TOKEN:?}"
threshold=${HUNG_REQUESTS_THRESHOLD:-10}
account=03095c60a92087ee7852931e8f110719
to=$(( $(date +%s) / 3600 * 3600 * 1000 ))
from=$(( to - 3600000 ))

count() {
  local response value
  response=$(curl -s --fail-with-body --max-time 60 \
    "https://api.cloudflare.com/client/v4/accounts/${account}/workers/observability/telemetry/query" \
    -H "Authorization: Bearer ${CLOUDFLARE_OBSERVABILITY_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg worker "$1" --argjson from "$from" --argjson to "$to" '{
      queryId: "adhoc", view: "calculations", chart: false,
      timeframe: {from: $from, to: $to},
      parameters: {
        calculations: [{operator: "count"}],
        filters: [
          {key: "$workers.scriptName", operation: "eq", type: "string", value: $worker},
          {key: "$workers.outcome", operation: "eq", type: "string", value: "canceled"},
          {key: "$workers.event.request.headers.sec-fetch-dest", operation: "eq", type: "string", value: "document"},
          {key: "$workers.wallTimeMs", operation: "gt", type: "number", value: 10000}
        ]
      }
    }')") || return 1
  jq -e '.success == true' <<< "$response" > /dev/null || return 1
  value=$(jq -r '.result.calculations[0].aggregates[0].value // 0' <<< "$response")
  echo "${value%.*}"
}

post() {
  local response
  response=$(curl -s https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer ${SLACK_TOKEN}" \
    -H 'Content-Type: application/json; charset=utf-8' \
    -d "$(jq -n --arg text "$1" '{channel: "it_tests", text: $text}')") || return 1
  [ "$(jq -r .ok <<< "$response")" = true ]
}

title="Hung page requests"
failures=""
for worker in dogchef-prod catchef-prod; do
  if n=$(count "$worker"); then
    [ "$n" -le "$threshold" ] || failures+="${worker}: ${n} in the last hour (threshold ${threshold})"$'\n'
  else
    failures+="${worker}: Cloudflare query failed"$'\n'
  fi
done

workflow=${GITHUB_WORKFLOW_REF#*/.github/workflows/}
workflow=${workflow%%@*}
previous=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow "$workflow" \
  --branch "$GITHUB_REF_NAME" --status completed --limit 20 --json conclusion \
  -q '[.[]|select(.conclusion=="success" or .conclusion=="failure")][0].conclusion // "unknown"') || previous=unknown
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

if [ -n "$failures" ]; then
  if [ "$previous" != failure ] && ! post "$(printf ':rotating_light: %s\n```\n%s```\n%s' "$title" "$failures" "$run_url")"; then
    gh run cancel "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" || true
    sleep 60
  fi
  exit 1
fi
if [ "$previous" = failure ]; then
  post "$(printf ':white_check_mark: %s recovered\n%s' "$title" "$run_url")" || exit 1
fi
