#!/usr/bin/env bash
# delegate.sh — 핸드오프 프롬프트 조립 + Codex CLI 헤드리스 실행 래퍼 (R2)
#
# 사용법:
#   delegate.sh <task-type> <task-id> <context-file> "<instruction>"
#
# 환경변수 오버라이드:
#   RULES_FILE      routing-rules.yaml 경로 (기본: <repo>/config/routing-rules.yaml)
#   TEMPLATES_DIR   핸드오프 템플릿 디렉토리 (기본: <repo>/templates)
#   ROUTER_DIR      런타임 산출물 디렉토리 (기본: $PWD/.router)
#   CODEX_BIN       백엔드 실행 파일 (테스트에서 mock-codex 주입 지점)
#   HANDOFF_CONSTRAINTS / HANDOFF_OUTPUT_FORMAT  템플릿 추가 치환 값
#
# 종료 코드:
#   0  성공 (.router/results/<task-id>.md 생성)
#   2  인자 오류
#   3  routing-rules.yaml 없음/파싱 실패 → 위임 전면 비활성화 (안전 기본값)
#   4  task-type 위임 불가 (delegate_if 미포함 또는 never_delegate)
#   5  백엔드(cline) 실행 파일 없음
#   6  실행 실패 (재시도 소진)
#   7  타임아웃 (재시도 소진)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

RULES_FILE=${RULES_FILE:-$ROOT_DIR/config/routing-rules.yaml}
TEMPLATES_DIR=${TEMPLATES_DIR:-$ROOT_DIR/templates}
ROUTER_DIR=${ROUTER_DIR:-$PWD/.router}

err() { printf 'delegate: %s\n' "$*" >&2; }

WORK_DIR=$(mktemp -d)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# --- 인자 검증 -------------------------------------------------------------
if [[ $# -ne 4 ]]; then
  err 'usage: delegate.sh <task-type> <task-id> <context-file> "<instruction>"'
  exit 2
fi
TASK_TYPE=$1
TASK_ID=$2
CONTEXT_FILE=$3
INSTRUCTION=$4

if [[ ! "$TASK_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  err "invalid task-id (allowed: A-Z a-z 0-9 . _ -): $TASK_ID"
  exit 2
fi
if [[ ! -f "$CONTEXT_FILE" ]]; then
  err "context file not found: $CONTEXT_FILE"
  exit 2
fi

# --- 규칙 로드 (R1: 규칙 없으면 위임 비활성화) -------------------------------
# mikefarah yq v4와 python-yq(kislyuk) 양쪽 지원: YAML→JSON 변환 후 jq로 일원화
yaml_to_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$1"
  else
    yq '.' "$1"
  fi
}

if [[ ! -f "$RULES_FILE" ]]; then
  err "routing rules not found: $RULES_FILE — delegation disabled (safe default)"
  exit 3
fi
if ! RULES_JSON=$(yaml_to_json "$RULES_FILE" 2>"$WORK_DIR/yq.err") \
   || ! jq -e 'type == "object"' <<<"$RULES_JSON" >/dev/null 2>&1; then
  err "failed to parse routing rules: $RULES_FILE — delegation disabled"
  [[ -s "$WORK_DIR/yq.err" ]] && cat "$WORK_DIR/yq.err" >&2
  exit 3
fi
rule() { jq -r "$1" <<<"$RULES_JSON"; }

# --- task-type 판정 (never_delegate 우선) -----------------------------------
if jq -e --arg t "$TASK_TYPE" '(.never_delegate // []) | index($t)' \
     <<<"$RULES_JSON" >/dev/null; then
  err "task-type '$TASK_TYPE' is in never_delegate — refusing to delegate"
  exit 4
fi
if ! jq -e --arg t "$TASK_TYPE" '(.delegate_if.task_type // []) | index($t)' \
     <<<"$RULES_JSON" >/dev/null; then
  err "task-type '$TASK_TYPE' is not in delegate_if.task_type — not delegatable"
  exit 4
fi

TIMEOUT_SEC=$(rule '.limits.timeout_sec // 180')
MAX_RETRIES=$(rule '.limits.max_retries // 1')
if [[ ! "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
  err "limits.timeout_sec / limits.max_retries must be integers"
  exit 3
fi

# --- 핸드오프 프롬프트 조립 ---------------------------------------------------
case "$TASK_TYPE" in
  test-stub)                    TPL_NAME=handoff-test-stub.md ;;
  docstring)                    TPL_NAME=handoff-docs.md ;;
  format-transform|classification) TPL_NAME=handoff-transform.md ;;
  *)                            TPL_NAME=handoff-codegen.md ;;
esac
TPL_FILE="$TEMPLATES_DIR/$TPL_NAME"
if [[ ! -f "$TPL_FILE" ]]; then
  err "handoff template not found: $TPL_FILE"
  exit 2
fi

INSTR_FILE="$WORK_DIR/instruction.txt"
printf '%s\n' "$INSTRUCTION" > "$INSTR_FILE"

PROMPT_FILE="$WORK_DIR/prompt.md"
# 플레이스홀더 치환: 본문은 파일에서 getline으로 읽어 특수문자(&, / 등)에 안전
awk -v tid="$TASK_ID" \
    -v instr="$INSTR_FILE" -v ctx="$CONTEXT_FILE" \
    -v constraints="${HANDOFF_CONSTRAINTS:-- (추가 제약 없음)}" \
    -v outfmt="${HANDOFF_OUTPUT_FORMAT:-마크다운 코드 블록 1개. 코드 외 텍스트 금지.}" '
  function emit(path,  line) {
    while ((getline line < path) > 0) print line
    close(path)
  }
  /\{\{INSTRUCTION\}\}/   { emit(instr); next }
  /\{\{CONTEXT\}\}/       { emit(ctx); next }
  /\{\{CONSTRAINTS\}\}/   { print constraints; next }
  /\{\{OUTPUT_FORMAT\}\}/ { print outfmt; next }
  { gsub(/\{\{TASK_ID\}\}/, tid); print }
' "$TPL_FILE" > "$PROMPT_FILE"

# --- 백엔드 실행 (P2에서 codex 어댑터로 교체할 격리 지점) ----------------------
BACKEND_BIN=${CODEX_BIN:-$(rule '.codex.command // "codex"')}
mapfile -t HEADLESS_ARGS < <(jq -r '(.codex.headless_args // [])[]' <<<"$RULES_JSON")

if ! command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  err "codex CLI not found: $BACKEND_BIN"
  err "install codex or set CODEX_BIN. run scripts/check-env.sh for diagnosis."
  exit 5
fi

RAW_OUT="$WORK_DIR/result.md"
BACKEND_ERR="$WORK_DIR/backend.err"

# 프롬프트는 stdin으로 전달한다. Q2(SPEC §9) 확정 시 호출 형태가 바뀔 수 있다.
run_backend() {
  timeout --kill-after=5 "$TIMEOUT_SEC" \
    "$BACKEND_BIN" ${HEADLESS_ARGS[@]+"${HEADLESS_ARGS[@]}"} \
    < "$PROMPT_FILE" > "$RAW_OUT" 2>"$BACKEND_ERR"
}

START_TS=$(date +%s)
attempt=0
final_rc=0
while :; do
  rc=0
  run_backend || rc=$?
  if [[ $rc -eq 0 ]]; then
    break
  fi
  if (( attempt >= MAX_RETRIES )); then
    final_rc=$rc
    break
  fi
  attempt=$((attempt + 1))
  err "backend attempt failed (rc=$rc), retrying ($attempt/$MAX_RETRIES)"
done
DURATION=$(( $(date +%s) - START_TS ))

# --- 토큰 추정 + 로깅 (R4) ----------------------------------------------------
# 추정 방식: 토큰 ≈ 문자수/4. 절감 추정은 결과 문자수/4 × 3
# (Claude가 직접 생성할 때의 사고 토큰 포함 추정 배수 — README에 명시)
PROMPT_CHARS=$(wc -c < "$PROMPT_FILE")
RESULT_CHARS=$(wc -c < "$RAW_OUT" 2>/dev/null || echo 0)
LOCAL_TOKENS=$(( (PROMPT_CHARS + RESULT_CHARS) / 4 ))

log_record() { # $1=verify_result $2=saved_tokens
  mkdir -p "$ROUTER_DIR" 2>/dev/null || true
  if ! jq -cn \
      --arg task_id "$TASK_ID" --arg type "$TASK_TYPE" \
      --arg verify_result "$1" --arg ts "$(date -u +%FT%TZ)" \
      --argjson local_tokens_est "$LOCAL_TOKENS" \
      --argjson claude_tokens_saved_est "$2" \
      --argjson retries "$attempt" --argjson duration_sec "$DURATION" \
      '{event: "route", route: "delegated", task_id: $task_id, type: $type,
        local_tokens_est: $local_tokens_est,
        claude_tokens_saved_est: $claude_tokens_saved_est,
        verify_result: $verify_result, retries: $retries,
        duration_sec: $duration_sec, ts: $ts}' \
      >> "$ROUTER_DIR/log.jsonl" 2>/dev/null; then
    err "warning: failed to write log record (delegation result unaffected)"
  fi
}

if [[ $final_rc -ne 0 ]]; then
  if [[ $final_rc -eq 124 || $final_rc -eq 137 ]]; then
    log_record "error:timeout" 0
    err "backend timed out after ${TIMEOUT_SEC}s (retries exhausted)"
    exit 7
  fi
  log_record "error:exec" 0
  err "backend failed (rc=$final_rc, retries exhausted)"
  [[ -s "$BACKEND_ERR" ]] && tail -5 "$BACKEND_ERR" >&2
  exit 6
fi

# --- 결과 회수 ----------------------------------------------------------------
mkdir -p "$ROUTER_DIR/results"
RESULT_FILE="$ROUTER_DIR/results/$TASK_ID.md"
cp "$RAW_OUT" "$RESULT_FILE"

# 조립한 프롬프트를 보존한다 → verify.sh의 doubt-driven 반증이 원본 의뢰를
# 컨텍스트로 사용한다 (검증 정확도↑, 감사 추적).
mkdir -p "$ROUTER_DIR/prompts"
cp "$PROMPT_FILE" "$ROUTER_DIR/prompts/$TASK_ID.md" 2>/dev/null || true

SAVED_TOKENS=$(( RESULT_CHARS * 3 / 4 ))
log_record "pending" "$SAVED_TOKENS"

echo "$RESULT_FILE"
