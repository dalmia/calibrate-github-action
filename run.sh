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
AGENTS_RAW="${CALIBRATE_AGENTS:-}"
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

# Split agent names on commas OR newlines (supports both "a,b,c" and the multiline
# YAML block form), trim whitespace, drop blanks. Each token is an agent name,
# kept as-is for display.
IFS=$',\n' read -ra _tokens <<<"$AGENTS_RAW"
LABELS=()
for t in "${_tokens[@]}"; do
  t="$(echo "$t" | xargs)"
  [[ -n "$t" ]] && LABELS+=("$t")
done

# Parallel arrays indexed alongside LABELS. AGENTS holds the resolved UUID used
# for API calls; LABELS holds the agent name, used in logs and the report.
AGENTS=()

if [[ ${#LABELS[@]} -gt 0 ]]; then
  # Explicit agents: resolve the given names to UUIDs in a single batch call.
  # Names are scoped to the caller's org by the API key, so a name maps to at
  # most one agent.
  #
  #   Resolve API:  POST /agents/resolve   {"names": ["alpha", ...]}
  #     200 -> {"resolved": {"alpha": "<uuid>", ...}, "not_found": ["missing", ...]}
  N=${#LABELS[@]}
  for ((i = 0; i < N; i++)); do AGENTS[i]=""; done

  echo "::group::Resolving agents"
  names_json="$(printf '%s\n' "${LABELS[@]}" | jq -R . | jq -s '{names: .}')"
  api POST "/agents/resolve" "$names_json"
  case "$API_HTTP_STATUS" in
    200) ;;
    401 | 403)
      echo "::error::authentication failed (HTTP ${API_HTTP_STATUS}) resolving agent names"
      echo "::error::check the api-key input — set it to a valid Calibrate key via the CALIBRATE_API_KEY secret."
      echo "::endgroup::"
      exit 2
      ;;
    *)
      detail="$(echo "$API_BODY" | jq -r '.detail // empty' 2>/dev/null)"
      [[ -z "$detail" ]] && detail="$API_BODY"
      echo "::error::failed to resolve agent names (HTTP ${API_HTTP_STATUS}): ${detail}"
      echo "::endgroup::"
      exit 2
      ;;
  esac

  # Map each name to its UUID from the "resolved" object; collect any misses.
  UNRESOLVED=()
  for ((i = 0; i < N; i++)); do
    AGENTS[i]="$(echo "$API_BODY" | jq -r --arg n "${LABELS[i]}" '.resolved[$n] // empty')"
    if [[ -n "${AGENTS[i]}" ]]; then
      echo "agent \"${LABELS[i]}\" -> ${AGENTS[i]}"
    else
      echo "::error::agent \"${LABELS[i]}\": no agent with that name in this org."
      UNRESOLVED+=("${LABELS[i]}")
    fi
  done

  # Fail fast: if any name didn't resolve, stop before triggering any runs.
  if [[ ${#UNRESOLVED[@]} -gt 0 ]]; then
    echo "::error::${#UNRESOLVED[@]} agent name(s) could not be resolved: ${UNRESOLVED[*]}"
    echo "::endgroup::"
    exit 2
  fi
  echo "::endgroup::"
else
  # No agents given: run every agent associated with this API key. The list API
  # returns both the name and the UUID for each, so we populate LABELS/AGENTS
  # directly and skip the resolve step — nothing downstream changes.
  #
  #   List API:  GET /agents
  #     200 -> [{"name": "alpha", "id": "<uuid>"}, ...]  (or {"agents": [...]})
  echo "::group::Listing agents"
  api GET "/agents"
  case "$API_HTTP_STATUS" in
    200) ;;
    401 | 403)
      echo "::error::authentication failed (HTTP ${API_HTTP_STATUS}) listing agents"
      echo "::error::check the api-key input — set it to a valid Calibrate key via the CALIBRATE_API_KEY secret."
      echo "::endgroup::"
      exit 2
      ;;
    *)
      detail="$(echo "$API_BODY" | jq -r '.detail // empty' 2>/dev/null)"
      [[ -z "$detail" ]] && detail="$API_BODY"
      echo "::error::failed to list agents (HTTP ${API_HTTP_STATUS}): ${detail}"
      echo "::endgroup::"
      exit 2
      ;;
  esac

  # Accept either a bare array or {"agents": [...]}; take name + UUID (id/uuid).
  while IFS=$'\t' read -r _nm _id; do
    [[ -n "$_nm" && -n "$_id" ]] || continue
    LABELS+=("$_nm"); AGENTS+=("$_id")
    echo "agent \"$_nm\" -> $_id"
  done < <(echo "$API_BODY" | jq -r '(.agents // .)[] | [.name, (.id // .uuid)] | @tsv')

  if [[ ${#LABELS[@]} -eq 0 ]]; then
    echo "::error::no agents found for this API key — create one in Calibrate, or pass the agents input."
    echo "::endgroup::"
    exit 2
  fi
  N=${#LABELS[@]}
  echo "::endgroup::"
fi

# Remaining parallel arrays, indexed alongside LABELS/AGENTS.
TASK=(); STATUS=(); TOTAL=(); PASSED=(); FAILED=()
for ((i = 0; i < N; i++)); do
  TASK[i]=""; STATUS[i]="not-started"; TOTAL[i]=0; PASSED[i]=0; FAILED[i]=0
done

# Triggering a run also validates the agent: the API returns distinct codes for
# bad auth (401/403), missing agent (404), and unrunnable agent (400, e.g.
# connection not verified or no linked tests). 401/403 are global — the key is
# bad, so every agent fails the same way — so we stop immediately. 404/400 are
# per-agent: report and keep going so one bad agent doesn't hide the rest.
echo "::group::Triggering runs"
for ((i = 0; i < N; i++)); do
  agent="${AGENTS[i]}"; label="${LABELS[i]}"
  [[ -z "$agent" ]] && continue   # unresolved name; already reported above

  api POST "/agent-tests/agent/${agent}/run" '{}'

  if [[ "$API_HTTP_STATUS" == "200" || "$API_HTTP_STATUS" == "201" ]]; then
    TASK[i]="$(echo "$API_BODY" | jq -r '.task_id')"
    if [[ -n "$APP_URL" ]]; then
      echo "agent ${label} -> ${APP_URL}/tests?tab=runs&runId=${TASK[i]}"
    else
      echo "agent ${label} -> run ${TASK[i]}"
    fi
    continue
  fi

  # API error message (FastAPI-style {"detail": "..."}), falling back to raw body.
  detail="$(echo "$API_BODY" | jq -r '.detail // empty' 2>/dev/null)"
  [[ -z "$detail" ]] && detail="$API_BODY"

  case "$API_HTTP_STATUS" in
    401 | 403)
      echo "::error::authentication failed (HTTP ${API_HTTP_STATUS}): ${detail}"
      echo "::error::check the api-key input — set it to a valid Calibrate key via the CALIBRATE_API_KEY secret."
      echo "::endgroup::"
      exit 2
      ;;
    404)
      echo "::error::agent ${label}: not found (HTTP 404) — the agent may have been deleted, or belongs to a different org than this API key."
      ;;
    400)
      echo "::error::agent ${label}: cannot run (HTTP 400): ${detail}"
      ;;
    *)
      echo "::error::agent ${label}: failed to start (HTTP ${API_HTTP_STATUS}): ${detail}"
      ;;
  esac
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
      echo "agent ${LABELS[i]}: ${st} (${PASSED[i]}/${TOTAL[i]} passed)"
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
  label="${LABELS[i]}"; tid="${TASK[i]}"; st="${STATUS[i]}"
  if [[ -z "$tid" ]]; then
    ROWS+="| \`${label}\` | — | ⚠️ not started |\n"
    ANY_PROBLEM=1
    continue
  fi
  t="${TOTAL[i]}"; p="${PASSED[i]}"; f="${FAILED[i]}"
  SUM_TOTAL=$((SUM_TOTAL + t)); SUM_PASSED=$((SUM_PASSED + p)); SUM_FAILED=$((SUM_FAILED + f))
  link="\`${tid}\`"
  [[ -n "$APP_URL" ]] && link="[view](${APP_URL}/tests?tab=runs&runId=${tid})"
  if [[ "$st" != "done" ]]; then
    ANY_PROBLEM=1
    ROWS+="| \`${label}\` | ${p}/${t} | ⚠️ ${st} ${link} |\n"
  elif [[ "$f" -gt 0 ]]; then
    ANY_PROBLEM=1
    ROWS+="| \`${label}\` | ${p}/${t} | ❌ ${f} failed ${link} |\n"
  else
    ROWS+="| \`${label}\` | ${p}/${t} | ✅ pass ${link} |\n"
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
