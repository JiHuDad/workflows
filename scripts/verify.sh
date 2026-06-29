#!/usr/bin/env bash
# verify.sh — 위임 결과 검수 + doubt-driven 반증 (R2 지원 / design.md §6)
#
# 사용법:
#   verify.sh <task-id> [test-command...]
#
# 검사 단계:
#   1. 기계적: 결과 파일 존재 + 비어있지 않음 + max_output_lines 이하
#   2. test-command 지정 시 실행하여 exit code로 pass/fail
#   3. 검증 등급이 adversarial이면 최고 LLM(reviewer)에 반증 의뢰:
#      "이 산출물이 틀렸다고 가정하고 결함을 찾아라" → VERDICT: PASS/FAIL
#
# 등급 결정 순서: VERIFY_TIER > verification_tier[task_type] > mechanical
#   (task_type은 log.jsonl의 마지막 route 레코드에서 역참조)
#
# 환경변수 오버라이드:
#   REVIEWER_BIN   검증 백엔드 실행 파일 (테스트에서 mock-reviewer 주입 지점)
#   VERIFY_TIER    등급 강제 (mechanical | adversarial)
#   RULES_FILE / ROUTER_DIR / TEMPLATES_DIR
#
# 결과는 log.jsonl에 verify 이벤트로 append (append-only,
# stats.sh가 task_id별 마지막 verify 레코드를 사용).
#
# 종료 코드: 0=pass, 1=fail, 2=인자 오류
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

RULES_FILE=${RULES_FILE:-$ROOT_DIR/config/routing-rules.yaml}
TEMPLATES_DIR=${TEMPLATES_DIR:-$ROOT_DIR/templates}
ROUTER_DIR=${ROUTER_DIR:-$PWD/.router}

err() { printf 'verify: %s\n' "$*" >&2; }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2317  # trap으로 호출됨 (모든 경로가 exit라 오탐 발생)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

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

RULES_JSON='{}'
MAX_LINES=500
if [[ -f "$RULES_FILE" ]] && RULES_JSON=$(yaml_to_json "$RULES_FILE" 2>/dev/null); then
  MAX_LINES=$(jq -r '.limits.max_output_lines // 500' <<<"$RULES_JSON")
else
  RULES_JSON='{}'
  err "warning: routing rules unavailable, using max_output_lines=$MAX_LINES"
fi

LOG_FILE="$ROUTER_DIR/log.jsonl"

log_verify() { # $1=result  [$2=tier $3=model]
  mkdir -p "$ROUTER_DIR" 2>/dev/null || true
  if ! jq -cn --arg task_id "$TASK_ID" --arg verify_result "$1" \
      --arg tier "${2:-mechanical}" --arg model "${3:-}" \
      --arg ts "$(date -u +%FT%TZ)" \
      '{event: "verify", task_id: $task_id, verify_result: $verify_result,
        tier: $tier, reviewer: $model, ts: $ts}' \
      >> "$LOG_FILE" 2>/dev/null; then
    err "warning: failed to write log record"
  fi
}

RESULT_FILE="$ROUTER_DIR/results/$TASK_ID.md"

# --- 1. 기계적 검사 ----------------------------------------------------------
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

# --- 2. 검증 등급 결정 -------------------------------------------------------
TIER=${VERIFY_TIER:-}
if [[ -z "$TIER" ]]; then
  TASK_TYPE=''
  if [[ -s "$LOG_FILE" ]]; then
    TASK_TYPE=$(jq -rs --arg id "$TASK_ID" \
      'map(select(.event == "route" and .task_id == $id)) | last | .type // empty' \
      "$LOG_FILE" 2>/dev/null || true)
  fi
  if [[ -n "$TASK_TYPE" ]]; then
    TIER=$(jq -r --arg t "$TASK_TYPE" \
      '.verification_tier[$t] // "mechanical"' <<<"$RULES_JSON")
  else
    TIER=mechanical
  fi
fi

if [[ "$TIER" != "adversarial" ]]; then
  log_verify "pass" "mechanical"
  echo "verify: pass ($TASK_ID, tier=mechanical)"
  exit 0
fi

# --- 3. doubt-driven 반증 (adversarial) --------------------------------------
REVIEWER_BIN=${REVIEWER_BIN:-$(jq -r '.reviewer.command // "claude"' <<<"$RULES_JSON")}

if ! command -v "$REVIEWER_BIN" >/dev/null 2>&1; then
  err "reviewer LLM not found: $REVIEWER_BIN"
  err "install it or set REVIEWER_BIN. run scripts/check-env.sh for diagnosis."
  log_verify "fail:no-reviewer" "adversarial" "$REVIEWER_BIN"
  exit 1
fi

mapfile -t REVIEWER_ARGS < <(jq -r '(.reviewer.headless_args // [])[]' <<<"$RULES_JSON")
REVIEW_TIMEOUT=$(jq -r '.reviewer.timeout_sec // .limits.timeout_sec // 180' <<<"$RULES_JSON")
[[ "$REVIEW_TIMEOUT" =~ ^[0-9]+$ ]] || REVIEW_TIMEOUT=180

# 반증 프롬프트 조립: {{PROMPT}}=원본 의뢰, {{RESULT}}=산출물 (특수문자 안전)
PROMPT_SRC="$ROUTER_DIR/prompts/$TASK_ID.md"
if [[ ! -s "$PROMPT_SRC" ]]; then
  PROMPT_SRC="$WORK_DIR/no-prompt.txt"
  printf '(원본 의뢰 기록 없음 — 산출물만으로 판단)\n' > "$PROMPT_SRC"
fi

TPL_FILE="$TEMPLATES_DIR/handoff-review.md"
if [[ ! -f "$TPL_FILE" ]]; then
  err "review template not found: $TPL_FILE"
  log_verify "fail:no-template" "adversarial" "$REVIEWER_BIN"
  exit 1
fi

REVIEW_PROMPT="$WORK_DIR/review-prompt.md"
awk -v tid="$TASK_ID" -v prompt="$PROMPT_SRC" -v result="$RESULT_FILE" '
  function emit(path,  line) {
    while ((getline line < path) > 0) print line
    close(path)
  }
  /\{\{PROMPT\}\}/ { emit(prompt); next }
  /\{\{RESULT\}\}/ { emit(result); next }
  { gsub(/\{\{TASK_ID\}\}/, tid); print }
' "$TPL_FILE" > "$REVIEW_PROMPT"

REVIEW_OUT="$WORK_DIR/review.out"
REVIEW_ERR="$WORK_DIR/review.err"
rc=0
timeout --kill-after=5 "$REVIEW_TIMEOUT" \
  "$REVIEWER_BIN" ${REVIEWER_ARGS[@]+"${REVIEWER_ARGS[@]}"} \
  < "$REVIEW_PROMPT" > "$REVIEW_OUT" 2>"$REVIEW_ERR" || rc=$?

if [[ $rc -ne 0 ]]; then
  err "reviewer execution failed (rc=$rc)"
  [[ -s "$REVIEW_ERR" ]] && tail -3 "$REVIEW_ERR" >&2
  log_verify "fail:doubt" "adversarial" "$REVIEWER_BIN"
  exit 1
fi

# VERDICT 계약: 마지막 'VERDICT: PASS|FAIL' 라인을 채택. 없으면 안전 기본값 fail.
VERDICT=$(grep -oiE 'VERDICT:[[:space:]]*(PASS|FAIL)' "$REVIEW_OUT" 2>/dev/null \
  | tail -1 | grep -oiE '(PASS|FAIL)' | tr '[:lower:]' '[:upper:]' || true)

if [[ "$VERDICT" == "PASS" ]]; then
  log_verify "pass" "adversarial" "$REVIEWER_BIN"
  echo "verify: pass ($TASK_ID, tier=adversarial, reviewer=$REVIEWER_BIN)"
  exit 0
fi

if [[ "$VERDICT" == "FAIL" ]]; then
  err "doubt-driven review found defects (VERDICT: FAIL)"
else
  err "reviewer returned no VERDICT line — treating as fail (safe default)"
fi
# 결함 근거를 노출하여 escalation 판단에 활용
[[ -s "$REVIEW_OUT" ]] && tail -20 "$REVIEW_OUT" >&2
log_verify "fail:doubt" "adversarial" "$REVIEWER_BIN"
exit 1
