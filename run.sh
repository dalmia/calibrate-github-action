#!/usr/bin/env bash
#
# Calibrate CI runner.
#
# Triggers all linked tests for each given agent, polls every run to completion,
# aggregates per-agent pass/fail, writes a GitHub job summary, posts/updates a PR
# comment on pull_request events, and (in 'gate' mode) exits non-zero on any
# failure so the check goes red.
#
# Talks only to the public REST API using an API key — no calibrate CLI needed.
# Kept bash-3.2 compatible (parallel indexed arrays, no associative arrays).

set -uo pipefail

API_KEY="${CALIBRATE_API_KEY:?api-key input is required}"
AGENTS_RAW="${CALIBRATE_AGENTS:?agents input is required}"
BASE_URL="${CALIBRATE_BASE_URL:?base-url input is required}"
APP_URL="${CALIBRATE_APP_URL:-}"
MODE="${CALIBRATE_MODE:-gate}"
POLL_INTERVAL="${CALIBRATE_POLL_INTERVAL:-5}"
TIMEOUT="${CALIBRATE_TIMEOUT:-1800}"

BASE_URL="${BASE_URL%/}"
APP_URL="${APP_URL%/}"

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "::error::missing required tool: $dep"; exit 2; }
done

_BODY_FILE="$(mktemp)"
trap 'rm -f "$_BODY_FILE"' EXIT

# api METHOD PATH [JSON_BODY] -> sets globals API_HTTP_STATUS and API_BODY.
#
# Must be called as a statement (not in `$(...)`), because it sets globals —
# command substitution would run it in a subshell and discard them. Body goes
# to a temp file via curl -o; the status code is the only thing on stdout.
API_HTTP_STATUS=""
API_BODY=""
api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    API_HTTP_STATUS="$(curl -sS -o "$_BODY_FILE" -w '%{http_code}' -X "$method" \
      "${BASE_URL}${path}" -H "X-API-Key: ${API_KEY}" \
      -H "Content-Type: application/json" -d "$body")"
  else
    API_HTTP_STATUS="$(curl -sS -o "$_BODY_FILE" -w '%{http_code}' -X "$method" \
      "${BASE_URL}${path}" -H "X-API-Key: ${API_KEY}")"
  fi
  API_BODY="$(cat "$_BODY_FILE")"
}

# Split comma-separated agents, trim whitespace, drop blanks.
IFS=',' read -ra _agents <<<"$AGENTS_RAW"
AGENTS=()
for a in "${_agents[@]}"; do
  a="$(echo "$a" | xargs)"
  [[ -n "$a" ]] && AGENTS+=("$a")
done
[[ ${#AGENTS[@]} -gt 0 ]] || { echo "::error::no agent UUIDs provided"; exit 2; }

# Parallel arrays indexed alongside AGENTS.
N=${#AGENTS[@]}
TASK=(); STATUS=(); TOTAL=(); PASSED=(); FAILED=()
for ((i = 0; i < N; i++)); do
  TASK[i]=""; STATUS[i]="not-started"; TOTAL[i]=0; PASSED[i]=0; FAILED[i]=0
done

echo "::group::Triggering runs"
for ((i = 0; i < N; i++)); do
  agent="${AGENTS[i]}"
  api POST "/agent-tests/agent/${agent}/run" '{}'
  if [[ "$API_HTTP_STATUS" != "200" && "$API_HTTP_STATUS" != "201" ]]; then
    echo "::error::failed to start run for agent ${agent} (HTTP ${API_HTTP_STATUS}): $(echo "$API_BODY" | jq -r '.detail // .' 2>/dev/null || echo "$API_BODY")"
    continue
  fi
  TASK[i]="$(echo "$API_BODY" | jq -r '.task_id')"
  echo "agent ${agent} -> run ${TASK[i]}"
done
echo "::endgroup::"

# Poll until every started run is terminal or we hit the timeout.
is_terminal() { [[ "$1" == "done" || "$1" == "failed" || "$1" == "cancelled" ]]; }
deadline=$(( $(date +%s) + TIMEOUT ))
echo "::group::Polling"
while :; do
  pending=0
  for ((i = 0; i < N; i++)); do
    tid="${TASK[i]}"
    [[ -z "$tid" ]] && continue
    is_terminal "${STATUS[i]}" && continue

    api GET "/agent-tests/run/${tid}"
    if [[ "$API_HTTP_STATUS" != "200" ]]; then
      echo "::warning::poll failed for ${tid} (HTTP ${API_HTTP_STATUS}); will retry"
      pending=1
      continue
    fi
    st="$(echo "$API_BODY" | jq -r '.status')"
    STATUS[i]="$st"
    if is_terminal "$st"; then
      TOTAL[i]="$(echo "$API_BODY" | jq -r '.total_tests // 0')"
      PASSED[i]="$(echo "$API_BODY" | jq -r '.passed // 0')"
      FAILED[i]="$(echo "$API_BODY" | jq -r '.failed // 0')"
      echo "agent ${AGENTS[i]}: ${st} (${PASSED[i]}/${TOTAL[i]} passed)"
    else
      pending=1
    fi
  done
  [[ "$pending" -eq 0 ]] && break
  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    echo "::error::timed out after ${TIMEOUT}s waiting for runs to finish"
    break
  fi
  sleep "$POLL_INTERVAL"
done
echo "::endgroup::"

# Aggregate.
SUM_TOTAL=0; SUM_PASSED=0; SUM_FAILED=0; ANY_PROBLEM=0
ROWS=""
for ((i = 0; i < N; i++)); do
  agent="${AGENTS[i]}"; tid="${TASK[i]}"; st="${STATUS[i]}"
  if [[ -z "$tid" ]]; then
    ROWS+="| \`${agent}\` | — | ⚠️ not started |\n"
    ANY_PROBLEM=1
    continue
  fi
  t="${TOTAL[i]}"; p="${PASSED[i]}"; f="${FAILED[i]}"
  SUM_TOTAL=$((SUM_TOTAL + t)); SUM_PASSED=$((SUM_PASSED + p)); SUM_FAILED=$((SUM_FAILED + f))
  link="\`${tid}\`"
  [[ -n "$APP_URL" ]] && link="[view](${APP_URL}/agent-tests/run/${tid})"
  if [[ "$st" != "done" ]]; then
    ANY_PROBLEM=1
    ROWS+="| \`${agent}\` | ${p}/${t} | ⚠️ ${st} ${link} |\n"
  elif [[ "$f" -gt 0 ]]; then
    ANY_PROBLEM=1
    ROWS+="| \`${agent}\` | ${p}/${t} | ❌ ${f} failed ${link} |\n"
  else
    ROWS+="| \`${agent}\` | ${p}/${t} | ✅ pass ${link} |\n"
  fi
done

if [[ "$SUM_FAILED" -gt 0 || "$ANY_PROBLEM" -eq 1 ]]; then
  HEADER="❌ **Calibrate: ${SUM_FAILED} test(s) failed** across ${N} agent(s)"
  CONCLUSION="failure"
else
  HEADER="✅ **Calibrate: all ${SUM_TOTAL} test(s) passed** across ${N} agent(s)"
  CONCLUSION="success"
fi

REPORT="$(printf '%b\n\n| Agent | Passed | Result |\n|---|---|---|\n%b' "$HEADER" "$ROWS")"

# Outputs.
{
  echo "total=${SUM_TOTAL}"
  echo "passed=${SUM_PASSED}"
  echo "failed=${SUM_FAILED}"
} >>"${GITHUB_OUTPUT:-/dev/null}"

# Job summary + console.
printf '%s\n' "$REPORT" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
printf '\n%s\n' "$REPORT"

# PR comment (find-or-update, codecov-style) on pull_request events.
if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_TOKEN:-}" ]]; then
  pr_number="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null)"
  if [[ -n "$pr_number" ]]; then
    MARKER="<!-- calibrate-action -->"
    gh_api() { curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }
    comments_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${pr_number}/comments"
    body_json="$(jq -n --arg b "${MARKER}"$'\n'"${REPORT}" '{body: $b}')"
    existing="$(gh_api "${comments_url}?per_page=100" | jq -r --arg m "$MARKER" 'map(select(.body|contains($m)))|.[0].id // empty')"
    if [[ -n "$existing" ]]; then
      gh_api -X PATCH "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/comments/${existing}" -d "$body_json" >/dev/null \
        && echo "Updated PR comment #${existing}"
    else
      gh_api -X POST "$comments_url" -d "$body_json" >/dev/null && echo "Posted PR comment"
    fi
  fi
fi

if [[ "$MODE" == "gate" && "$CONCLUSION" == "failure" ]]; then
  exit 1
fi
exit 0
