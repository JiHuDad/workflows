#!/usr/bin/env bash
# stats.sh — log.jsonl 집계 → 위임률·검수통과율·추정 절감 토큰 리포트 (R4)
#
# 사용법: stats.sh [log-file]   (기본: $PWD/.router/log.jsonl)
set -euo pipefail

ROUTER_DIR=${ROUTER_DIR:-$PWD/.router}
LOG_FILE=${1:-$ROUTER_DIR/log.jsonl}

if [[ ! -s "$LOG_FILE" ]]; then
  echo "stats: no log records found at $LOG_FILE" >&2
  exit 1
fi

jq -rs '
  map(select(.event == "route")) as $routes
  | map(select(.event == "verify")) as $verifies
  # task_id별 마지막 verify 레코드 (append-only 로그이므로 마지막이 최신)
  | ($verifies | group_by(.task_id) | map(.[-1])
     | map({key: .task_id, value: .verify_result}) | from_entries) as $vlast
  | ($routes | length) as $total
  | ($routes | map(select(.route == "delegated")) | length) as $delegated
  | ($routes | map(select(.route == "direct")) | length) as $direct
  | ($routes | map(select(.route == "fallback")) | length) as $fallback
  | ($routes | map(select(.route == "delegated"
        and ($vlast[.task_id] // .verify_result) == "pass")) | length) as $passed
  | ($routes | map(select(.route == "delegated"
        and ($vlast[.task_id] // .verify_result) == "pass")
      | .claude_tokens_saved_est) | add // 0) as $saved
  | "== llm-task-router stats ==",
    "routing decisions : \($total) (delegated \($delegated), direct \($direct), fallback \($fallback))",
    "delegation rate   : \(if $total > 0 then ($delegated * 100 / $total | floor) else 0 end)%",
    "verify pass rate  : \(if $delegated > 0 then ($passed * 100 / $delegated | floor) else 0 end)% (\($passed)/\($delegated))",
    "est. tokens saved : \($saved) (verified-pass tasks only; est = chars/4, see README)",
    "",
    "-- by task_type (delegated) --",
    ($routes | map(select(.route == "delegated")) | group_by(.type) | map(
      "\(.[0].type): \(length) tasks, " +
      "\(map(select(($vlast[.task_id] // .verify_result) == "pass")) | length) passed, " +
      "\(map(.claude_tokens_saved_est) | add // 0) tokens saved"
    ) | .[])
' "$LOG_FILE"
