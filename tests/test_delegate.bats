#!/usr/bin/env bats
# delegate.sh 단위 테스트 (mock-cline 사용)

setup() {
  TEST_TMP=$(mktemp -d)
  export ROUTER_DIR="$TEST_TMP/.router"
  export RULES_FILE="$TEST_TMP/rules.yaml"
  export CODEX_BIN="$BATS_TEST_DIRNAME/fixtures/mock-codex"
  export MOCK_MODE=ok
  unset MOCK_STATE_FILE || true

  DELEGATE="$BATS_TEST_DIRNAME/../scripts/delegate.sh"
  cp "$BATS_TEST_DIRNAME/../config/routing-rules.yaml" "$RULES_FILE"

  CTX="$TEST_TMP/ctx.md"
  printf 'target file: src/calc.py\nfunction signature: add(a, b)\n' > "$CTX"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# 빠른 타임아웃/재시도 설정의 규칙 파일 생성 헬퍼
write_fast_rules() { # $1=timeout_sec $2=max_retries
  cat > "$RULES_FILE" <<EOF
cline:
  command: cline
  headless_args: []
delegate_if:
  task_type: [boilerplate, test-stub]
never_delegate: [security-sensitive]
limits:
  timeout_sec: $1
  max_retries: $2
  max_output_lines: 500
EOF
}

@test "R1: 규칙 파일 없으면 위임 비활성화 (exit 3)" {
  export RULES_FILE="$TEST_TMP/does-not-exist.yaml"
  run "$DELEGATE" boilerplate t1 "$CTX" "generate add()"
  [ "$status" -eq 3 ]
  [[ "$output" == *"delegation disabled"* ]]
}

@test "R1: 규칙 파일 파싱 실패 시 위임 중단 (exit 3)" {
  printf '{{{{ not yaml: [unclosed\n' > "$RULES_FILE"
  run "$DELEGATE" boilerplate t1 "$CTX" "generate add()"
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed to parse"* ]]
}

@test "R3 지원: never_delegate 타입은 거부 (exit 4)" {
  run "$DELEGATE" security-sensitive t1 "$CTX" "rewrite auth"
  [ "$status" -eq 4 ]
  [[ "$output" == *"never_delegate"* ]]
}

@test "delegate_if 미포함 타입은 거부 (exit 4)" {
  run "$DELEGATE" unknown-type t1 "$CTX" "do something"
  [ "$status" -eq 4 ]
}

@test "정상 위임: 결과 파일 + 로그 레코드 생성 (exit 0)" {
  run "$DELEGATE" boilerplate t-ok "$CTX" "generate add()"
  [ "$status" -eq 0 ]
  [ -s "$ROUTER_DIR/results/t-ok.md" ]
  grep -q 'def add' "$ROUTER_DIR/results/t-ok.md"

  [ -s "$ROUTER_DIR/log.jsonl" ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .route <<<"$record")" = "delegated" ]
  [ "$(jq -r .task_id <<<"$record")" = "t-ok" ]
  [ "$(jq -r .verify_result <<<"$record")" = "pending" ]
  [ "$(jq -r .retries <<<"$record")" = "0" ]
  [ "$(jq -r .claude_tokens_saved_est <<<"$record")" -gt 0 ]
}

@test "타임아웃: 프로세스 정리 후 실패 기록 (exit 7)" {
  write_fast_rules 1 0
  export MOCK_MODE=slow
  run "$DELEGATE" boilerplate t-slow "$CTX" "generate add()"
  [ "$status" -eq 7 ]
  [[ "$output" == *"timed out"* ]]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "error:timeout" ]
  [ ! -f "$ROUTER_DIR/results/t-slow.md" ]
}

@test "codex 미설치: 명확한 안내와 비제로 종료 (exit 5)" {
  export CODEX_BIN="$TEST_TMP/no-such-codex"
  run "$DELEGATE" boilerplate t1 "$CTX" "generate add()"
  [ "$status" -eq 5 ]
  [[ "$output" == *"not found"* ]]
}

@test "실행 실패: 재시도 소진 후 exit 6" {
  write_fast_rules 30 1
  export MOCK_MODE=fail
  run "$DELEGATE" boilerplate t-fail "$CTX" "generate add()"
  [ "$status" -eq 6 ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "error:exec" ]
  [ "$(jq -r .retries <<<"$record")" = "1" ]
}

@test "재시도: 1회 실패 후 성공하면 exit 0 + retries=1" {
  write_fast_rules 30 1
  export MOCK_MODE=fail-then-ok
  export MOCK_STATE_FILE="$TEST_TMP/mock-state"
  run "$DELEGATE" boilerplate t-retry "$CTX" "generate add()"
  [ "$status" -eq 0 ]
  [ -s "$ROUTER_DIR/results/t-retry.md" ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .retries <<<"$record")" = "1" ]
  [ "$(jq -r .verify_result <<<"$record")" = "pending" ]
}

@test "인자 오류: 잘못된 task-id (exit 2)" {
  run "$DELEGATE" boilerplate '../evil' "$CTX" "generate add()"
  [ "$status" -eq 2 ]
}

@test "특수문자 instruction이 프롬프트에 안전하게 들어감" {
  run "$DELEGATE" boilerplate t-special "$CTX" 'replace a/b with &c {{weird}}'
  [ "$status" -eq 0 ]
}

@test "end-to-end: delegate → verify pass → stats 집계" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  STATS="$BATS_TEST_DIRNAME/../scripts/stats.sh"

  run "$DELEGATE" boilerplate t-e2e "$CTX" "generate add()"
  [ "$status" -eq 0 ]

  run "$VERIFY" t-e2e true
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass"* ]]

  run "$STATS" "$ROUTER_DIR/log.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"delegation rate   : 100%"* ]]
  [[ "$output" == *"verify pass rate  : 100%"* ]]
}

@test "verify: 결과 파일 없으면 fail (exit 1)" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  run "$VERIFY" t-missing
  [ "$status" -eq 1 ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "fail:no-result" ]
}

@test "verify: 테스트 명령 실패 시 fail:tests 기록" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  run "$DELEGATE" boilerplate t-vfail "$CTX" "generate add()"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-vfail false
  [ "$status" -eq 1 ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "fail:tests" ]
}

# --- doubt-driven 반증 (adversarial 검증) ------------------------------------

@test "adversarial: 반증 PASS → verify pass (tier=adversarial)" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  export REVIEWER_BIN="$BATS_TEST_DIRNAME/fixtures/mock-reviewer"
  export MOCK_REVIEW=pass
  run "$DELEGATE" test-stub t-adv-ok "$CTX" "generate test stub"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-adv-ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier=adversarial"* ]]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "pass" ]
  [ "$(jq -r .tier <<<"$record")" = "adversarial" ]
}

@test "adversarial: 반증 FAIL → fail:doubt + 비제로 종료" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  export REVIEWER_BIN="$BATS_TEST_DIRNAME/fixtures/mock-reviewer"
  export MOCK_REVIEW=fail
  run "$DELEGATE" test-stub t-adv-fail "$CTX" "generate test stub"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-adv-fail
  [ "$status" -eq 1 ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "fail:doubt" ]
}

@test "adversarial: VERDICT 라인 없으면 안전 기본값 fail:doubt" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  export REVIEWER_BIN="$BATS_TEST_DIRNAME/fixtures/mock-reviewer"
  export MOCK_REVIEW=noverdict
  run "$DELEGATE" test-stub t-adv-nov "$CTX" "generate test stub"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-adv-nov
  [ "$status" -eq 1 ]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "fail:doubt" ]
}

@test "mechanical 등급은 reviewer 미호출 (불필요한 비용 없음)" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  # reviewer를 존재하지 않는 경로로 설정해도 boilerplate(mechanical)는 통과해야 함
  export REVIEWER_BIN="$TEST_TMP/no-such-reviewer"
  run "$DELEGATE" boilerplate t-mech "$CTX" "generate add()"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-mech
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier=mechanical"* ]]
}

@test "adversarial: reviewer 미설치 시 fail:no-reviewer" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  export REVIEWER_BIN="$TEST_TMP/no-such-reviewer"
  run "$DELEGATE" test-stub t-adv-nobin "$CTX" "generate test stub"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-adv-nobin
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  record=$(tail -1 "$ROUTER_DIR/log.jsonl")
  [ "$(jq -r .verify_result <<<"$record")" = "fail:no-reviewer" ]
}

@test "VERIFY_TIER 환경변수로 등급 강제 (adversarial→mechanical)" {
  VERIFY="$BATS_TEST_DIRNAME/../scripts/verify.sh"
  export REVIEWER_BIN="$TEST_TMP/no-such-reviewer"
  export VERIFY_TIER=mechanical
  run "$DELEGATE" test-stub t-force "$CTX" "generate test stub"
  [ "$status" -eq 0 ]
  run "$VERIFY" t-force
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier=mechanical"* ]]
}
