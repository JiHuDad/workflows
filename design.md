# design.md — llm-task-router 상세 설계

> SDD 승인 게이트 #2: 사용자 승인 후 Phase 1 구현 시작

## 1. 전체 데이터 흐름

```
Claude Code (SKILL.md 규약)
   │
   │ 1. 작업 분류 (task_type 결정)
   │ 2. routing-rules.yaml 대조 → 위임 가능 판정
   ▼
scripts/delegate.sh <task-type> <task-id> <context-file> "<instruction>"
   │
   ├─ a. 규칙 로드: config/routing-rules.yaml (없으면 즉시 실패, exit 3)
   ├─ b. task-type 검증: delegate_if.task_type 포함 + never_delegate 미포함
   ├─ c. 프롬프트 조립: templates/handoff-<type>.md 의 플레이스홀더 치환
   │      {{INSTRUCTION}} {{CONTEXT}} {{CONSTRAINTS}} {{OUTPUT_FORMAT}}
   ├─ d. run_backend() 호출: cline 헤드리스 실행 (timeout 래핑)
   │      실패/타임아웃 시 max_retries 만큼 재시도
   ├─ e. 결과 저장: .router/results/<task-id>.md
   └─ f. 로그 기록: .router/log.jsonl (1줄 JSON append)
   ▼
scripts/verify.sh <task-id> [test-command]
   │  결과 파일 존재·비어있지 않음·max_output_lines 이하 확인
   │  test-command 지정 시 실행, 결과를 log.jsonl에 verify_result로 기록
   ▼
Claude Code가 결과 채택 / 1회 재위임 / 직접 수행 결정
```

## 2. 컴포넌트 설계

### 2.1 config/routing-rules.yaml

SPEC §6 R1의 스키마를 그대로 사용. 추가 필드:

```yaml
backend: cline            # P2에서 codex 추가 예정
cline:
  command: cline          # 실행 파일명 (PATH 또는 절대경로)
  headless_args: ["task", "--non-interactive"]   # Q2 확정 전 기본값, 주석으로 대안 명시
```

### 2.2 delegate.sh

**인터페이스**: `delegate.sh <task-type> <task-id> <context-file> "<instruction>"`

**종료 코드 규약**:
| 코드 | 의미 |
|------|------|
| 0 | 성공 (결과 파일 생성됨) |
| 2 | 인자 오류 |
| 3 | routing-rules.yaml 없음/파싱 실패 → 위임 비활성화 |
| 4 | task-type 위임 불가 (delegate_if 미포함 또는 never_delegate) |
| 5 | cline 미설치 |
| 6 | 실행 실패 (재시도 소진) |
| 7 | 타임아웃 (재시도 소진) |

**핵심 함수 구조**:
```bash
load_rules()        # yq로 파싱, 실패 시 exit 3
check_task_type()   # delegate_if/never_delegate 대조, 실패 시 exit 4
build_prompt()      # 템플릿 플레이스홀더 치환 → 임시 파일
run_backend()       # $CLINE_BIN 환경변수 또는 rules의 command 사용
                    # timeout "${timeout_sec}s" 로 래핑, kill 후 정리
log_record()        # jq -n 으로 JSONL 1줄 생성, append
```

- `CLINE_BIN` 환경변수로 실행 파일 오버라이드 가능 → 테스트에서 mock-cline 주입 지점
- 토큰 추정: `local_tokens_est = (프롬프트 문자수 + 결과 문자수) / 4`, `claude_tokens_saved_est = 결과 문자수 / 4 * 3` (Claude가 직접 생성+사고 토큰 포함 추정 배수 3, README에 명시)

### 2.3 check-env.sh

순차 점검, 각 항목 `[OK]`/`[FAIL]` 출력:
1. `cline` 실행 파일 존재 (`command -v`)
2. `yq`, `jq` 존재
3. `cline auth` 상태 확인 (실패 시 폐쇄망 안내 + R10 SDK 래퍼 대안 문구)
4. 모델 1회 핑 (`--ping-test` 플래그 시에만, 토큰 소모 방지)

### 2.4 verify.sh

`verify.sh <task-id> [test-command...]`
- 결과 파일 존재 + 비어있지 않음 + `max_output_lines` 이하
- test-command 지정 시 실행, exit code로 pass/fail
- 결과를 log.jsonl의 해당 task_id 레코드 갱신이 아닌 **새 verify 레코드 append** (JSONL은 append-only 유지, stats.sh가 task_id별 마지막 레코드 사용)

### 2.5 stats.sh

jq 단일 패스 집계:
- 총 작업 수, 위임률 (delegated / 전체)
- 검수 통과율 (verify_result == "pass" / delegated)
- 추정 절감 토큰 합계, task_type별 분해

### 2.6 templates/handoff-*.md

공통 구조 (4종 모두 동일 골격, 본문만 특화):
```markdown
# Task: {{TASK_ID}}
## Instruction
{{INSTRUCTION}}
## Context
{{CONTEXT}}
## Constraints
- 지정된 파일 외 수정 금지
- 출력은 코드 블록만, 설명 최소화
- {{CONSTRAINTS}}
## Output Format
{{OUTPUT_FORMAT}}
```
치환은 `sed`가 아닌 bash 파라미터 확장 + `awk`로 처리 (특수문자 안전).
실제 치환 구현: 템플릿을 읽어 placeholder 라인을 파일 내용으로 바꾸는 awk 스크립트 (instruction에 `/`나 `&` 포함돼도 안전).

### 2.7 tests/

- `fixtures/mock-cline`: 환경변수 `MOCK_MODE`에 따라 동작 분기
  - `ok`(기본): 고정 응답 출력 후 exit 0
  - `slow`: 10초 sleep (타임아웃 테스트용, rules의 timeout을 1초로 오버라이드)
  - `fail`: exit 1
- `test_delegate.bats` 케이스:
  1. 규칙 파일 없음 → exit 3
  2. never_delegate 타입 → exit 4
  3. 정상 위임 → exit 0 + 결과 파일 존재 + log.jsonl 레코드 생성
  4. 타임아웃 → exit 7 + 실패 로그
  5. cline 미설치 (CLINE_BIN=/nonexistent) → exit 5
  6. 재시도: fail 1회 후 성공하는 mock → exit 0 + retries=1 기록

### 2.8 .gitignore

```
.router/
*.tmp
```

## 3. 의존성

| 도구 | 용도 | 폐쇄망 영향 |
|------|------|------------|
| bash ≥ 4 | 전체 | 없음 |
| yq (mikefarah v4) | YAML 파싱 | 설치 시점만 |
| jq | JSONL 생성/집계 | 설치 시점만 |
| timeout (coreutils) | 타임아웃 | 없음 |
| bats-core | 테스트 (개발 시만) | 런타임 불필요 |

## 4. 에러 처리 원칙

- 모든 스크립트 `set -euo pipefail` + `trap`으로 임시파일/자식 프로세스 정리
- 위임 실패는 **항상 0이 아닌 종료 코드 + stderr 한 줄 사유** → Claude Code가 fallback 판단 가능
- log.jsonl 기록 실패는 위임 성공 여부에 영향 주지 않음 (best-effort, stderr 경고만)

## 5. Phase 1 구현 순서

1. `.gitignore`, 디렉토리 골격
2. `config/routing-rules.yaml`
3. `templates/` 4종
4. `scripts/delegate.sh` (mock 기준으로 개발)
5. `scripts/check-env.sh`, `verify.sh`, `stats.sh`
6. `tests/fixtures/mock-cline`, `tests/test_delegate.bats`
7. shellcheck + bats 전체 통과 확인

---

## 승인 요청

이 design.md에 동의하시면 **"승인"** 이라고 답해주세요. Phase 1 구현을 시작합니다.
