#!/usr/bin/env bash
# check-env.sh — 위임 환경 사전 점검 (R5)
#
# 사용법:
#   check-env.sh [--ping-test]
#
# 점검 항목: codex 실행 파일, yq/jq/timeout, 규칙 파일 파싱,
# --ping-test 지정 시 모델 1회 핑 (토큰 소모가 있으므로 기본 비활성).
#
# 종료 코드: 0=모든 필수 항목 통과, 1=하나 이상 실패
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
RULES_FILE=${RULES_FILE:-$ROOT_DIR/config/routing-rules.yaml}

PING_TEST=false
[[ "${1:-}" == "--ping-test" ]] && PING_TEST=true

FAIL=0
ok()   { printf '[OK]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAIL=1; }
note() { printf '       %s\n' "$*"; }

# --- 필수 도구 ---------------------------------------------------------------
for tool in yq jq timeout; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found: $(command -v "$tool")"
  else
    fail "$tool not found — install it (macOS: brew install $tool / Ubuntu: apt install $tool)"
  fi
done

# --- YAML 파싱 헬퍼 ----------------------------------------------------------
yaml_to_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$1"
  else
    yq '.' "$1"
  fi
}

# --- codex 실행 파일 ---------------------------------------------------------
BACKEND_BIN=${CODEX_BIN:-codex}
if [[ -z "${CODEX_BIN:-}" && -f "$RULES_FILE" ]] && command -v yq >/dev/null 2>&1; then
  BACKEND_BIN=$(yaml_to_json "$RULES_FILE" 2>/dev/null \
    | jq -r '.codex.command // "codex"' 2>/dev/null || echo codex)
fi

if command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  ok "codex found: $(command -v "$BACKEND_BIN")"
  VERSION=$("$BACKEND_BIN" --version 2>/dev/null | head -1 || true)
  [[ -n "$VERSION" ]] && note "version: $VERSION"
else
  fail "codex CLI not found: $BACKEND_BIN"
  note "install: npm install -g @openai/codex"
  note "또는 CODEX_BIN 환경변수에 절대 경로를 지정하세요."
fi

# --- Claude Code 확인 --------------------------------------------------------
if command -v claude >/dev/null 2>&1; then
  ok "claude (Claude Code) found: $(command -v claude)"
  CL_VERSION=$(claude --version 2>/dev/null | head -1 || true)
  [[ -n "$CL_VERSION" ]] && note "version: $CL_VERSION"
else
  note "claude (Claude Code) not found — SKILL.md 자동 라우팅 불가"
  note "install: npm install -g @anthropic-ai/claude-code"
fi

# --- 규칙 파일 ---------------------------------------------------------------
if [[ -f "$RULES_FILE" ]]; then
  if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
     && yaml_to_json "$RULES_FILE" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1; then
    ok "routing rules parse OK: $RULES_FILE"
    HEADLESS=$(yaml_to_json "$RULES_FILE" 2>/dev/null \
      | jq -r '(.codex.headless_args // []) | join(" ")' 2>/dev/null || echo "(none)")
    note "codex.headless_args: [${HEADLESS}]"
    note "headless_args가 비어 있으면 routing-rules.yaml에서 설정하세요."
  else
    fail "routing rules exist but fail to parse: $RULES_FILE"
  fi
else
  fail "routing rules not found: $RULES_FILE (delegation will be disabled)"
fi

# --- 모델 핑 (옵션) ----------------------------------------------------------
if $PING_TEST && command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  HEADLESS_ARGS=()
  if [[ -f "$RULES_FILE" ]]; then
    mapfile -t HEADLESS_ARGS < <(yaml_to_json "$RULES_FILE" 2>/dev/null \
      | jq -r '(.codex.headless_args // [])[]' 2>/dev/null || true)
  fi
  if printf 'Reply with the single word: pong\n' \
       | timeout 30 "$BACKEND_BIN" ${HEADLESS_ARGS[@]+"${HEADLESS_ARGS[@]}"} \
       >/dev/null 2>&1; then
    ok "model ping succeeded"
  else
    fail "model ping failed (timeout 30s) — codex 실행 환경을 확인하세요"
    note "codex --help 로 올바른 headless_args를 확인하세요"
  fi
fi

if [[ $FAIL -eq 0 ]]; then
  echo "check-env: all checks passed"
else
  echo "check-env: one or more checks FAILED" >&2
fi
exit "$FAIL"
