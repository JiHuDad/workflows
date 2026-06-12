#!/usr/bin/env bash
# check-env.sh — 위임 환경 사전 점검 (R5)
#
# 사용법:
#   check-env.sh [--ping-test]
#
# 점검 항목: cline 실행 파일, yq/jq/timeout, cline 인증 상태,
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
    fail "$tool not found — install it (air-gapped: include in your offline package set)"
  fi
done

# --- cline 실행 파일 -----------------------------------------------------------
yaml_to_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$1"
  else
    yq '.' "$1"
  fi
}

BACKEND_BIN=${CLINE_BIN:-cline}
if [[ -z "${CLINE_BIN:-}" && -f "$RULES_FILE" ]] && command -v yq >/dev/null 2>&1; then
  BACKEND_BIN=$(yaml_to_json "$RULES_FILE" 2>/dev/null \
    | jq -r '.cline.command // "cline"' 2>/dev/null || echo cline)
fi

if command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  ok "cline found: $(command -v "$BACKEND_BIN")"
  VERSION=$("$BACKEND_BIN" --version 2>/dev/null | head -1 || true)
  [[ -n "$VERSION" ]] && note "version: $VERSION"
else
  fail "cline CLI not found: $BACKEND_BIN"
  note "install cline, or set CLINE_BIN to its absolute path."
fi

# --- 인증 상태 (Q1: 폐쇄망에서 막힐 수 있음) ------------------------------------
if command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  if "$BACKEND_BIN" auth status >/dev/null 2>&1 \
     || "$BACKEND_BIN" auth --check >/dev/null 2>&1; then
    ok "cline auth looks OK"
  else
    fail "cline auth check failed (or auth subcommand unsupported)"
    note "폐쇄망에서 cline 인증이 불가하면 SPEC §6 R10 (Cline SDK 래퍼)을"
    note "P0로 승격하는 것을 검토하세요. (SPEC §9 Q1)"
  fi
fi

# --- 규칙 파일 ----------------------------------------------------------------
if [[ -f "$RULES_FILE" ]]; then
  if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
     && yaml_to_json "$RULES_FILE" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1; then
    ok "routing rules parse OK: $RULES_FILE"
  else
    fail "routing rules exist but fail to parse: $RULES_FILE"
  fi
else
  fail "routing rules not found: $RULES_FILE (delegation will be disabled)"
fi

# --- 모델 핑 (옵션) ------------------------------------------------------------
if $PING_TEST && command -v "$BACKEND_BIN" >/dev/null 2>&1; then
  HEADLESS_ARGS=()
  if [[ -f "$RULES_FILE" ]]; then
    mapfile -t HEADLESS_ARGS < <(yaml_to_json "$RULES_FILE" 2>/dev/null \
      | jq -r '(.cline.headless_args // [])[]' 2>/dev/null || true)
  fi
  if printf 'Reply with the single word: pong\n' \
       | timeout 30 "$BACKEND_BIN" ${HEADLESS_ARGS[@]+"${HEADLESS_ARGS[@]}"} \
       >/dev/null 2>&1; then
    ok "model ping succeeded"
  else
    fail "model ping failed (timeout 30s) — check local model server is running"
  fi
fi

if [[ $FAIL -eq 0 ]]; then
  echo "check-env: all checks passed"
else
  echo "check-env: one or more checks FAILED" >&2
fi
exit "$FAIL"
