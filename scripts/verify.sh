#!/usr/bin/env bash
# verify.sh — 위임 결과 검수 (R2 지원)
#
# 사용법:
#   verify.sh <task-id> [test-command...]
#
# 검사 항목:
#   1. 결과 파일 존재 + 비어있지 않음
#   2. limits.max_output_lines 이하
#   3. test-command 지정 시 실행하여 exit code로 pass/fail 판정
#
# 결과는 log.jsonl에 verify 이벤트로 append 한다 (append-only,
# stats.sh가 task_id별 마지막 verify 레코드를 사용).
#
# 종료 코드: 0=pass, 1=fail, 2=인자 오류
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

RULES_FILE=${RULES_FILE:-$ROOT_DIR/config/routing-rules.yaml}
ROUTER_DIR=${ROUTER_DIR:-$PWD/.router}

err() { printf 'verify: %s\n' "$*" >&2; }

if [[ $# -lt 1 ]]; then
  err 'usage: verify.sh <task-id> [test-command...]'
  exit 2
fi
TASK_ID=$1
shift

if [[ ! "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  err "invalid task-id: $TASK_ID"
  exit 2
fi

yaml_to_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$1"
  else
    yq '.' "$1"
  fi
}

MAX_LINES=500
if [[ -f "$RULES_FILE" ]] && RULES_JSON=$(yaml_to_json "$RULES_FILE" 2>/dev/null); then
  MAX_LINES=$(jq -r '.limits.max_output_lines // 500' <<<"$RULES_JSON")
else
  err "warning: routing rules unavailable, using max_output_lines=$MAX_LINES"
fi

log_verify() { # $1=result
  mkdir -p "$ROUTER_DIR" 2>/dev/null || true
  if ! jq -cn --arg task_id "$TASK_ID" --arg verify_result "$1" \
      --arg ts "$(date -u +%FT%TZ)" \
      '{event: "verify", task_id: $task_id, verify_result: $verify_result, ts: $ts}' \
      >> "$ROUTER_DIR/log.jsonl" 2>/dev/null; then
    err "warning: failed to write log record"
  fi
}

RESULT_FILE="$ROUTER_DIR/results/$TASK_ID.md"

if [[ ! -s "$RESULT_FILE" ]]; then
  err "result file missing or empty: $RESULT_FILE"
  log_verify "fail:no-result"
  exit 1
fi

LINES=$(wc -l < "$RESULT_FILE")
if (( LINES > MAX_LINES )); then
  err "result exceeds max_output_lines ($LINES > $MAX_LINES)"
  log_verify "fail:too-long"
  exit 1
fi

if [[ $# -gt 0 ]]; then
  if ! "$@"; then
    err "test command failed: $*"
    log_verify "fail:tests"
    exit 1
  fi
fi

log_verify "pass"
echo "verify: pass ($TASK_ID)"
