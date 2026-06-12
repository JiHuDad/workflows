# llm-task-router

Claude Code가 단순·반복 작업을 Codex CLI에 위임하는 하이브리드 LLM 라우팅 툴킷.

---

## 구조

```
Claude Code (오케스트레이터)
  └─ SKILL.md 읽음 → 위임 결정
       └─ scripts/delegate.sh
            ├─ config/routing-rules.yaml  (위임 조건)
            ├─ templates/handoff-*.md     (프롬프트 템플릿)
            └─ Codex CLI (실행 백엔드)
                 └─ .router/results/<task-id>.md
```

---

## 사전 요구사항

| 도구 | 설치 | 용도 |
|------|------|------|
| `codex` | `npm install -g @openai/codex` | 위임 백엔드 |
| `claude` | `npm install -g @anthropic-ai/claude-code` | 오케스트레이터 |
| `jq` | `brew install jq` / `apt install jq` | JSON 처리 |
| `yq` | `pip install yq` / `brew install yq` | YAML 파싱 |
| `bats` | `brew install bats-core` / `npm install -g bats` | 테스트 실행 |

---

## 설치

```bash
git clone https://github.com/jihudad/workflows.git
cd workflows
```

---

## 초기 설정

### 1. 환경 점검

```bash
./scripts/check-env.sh
```

모든 항목이 `[OK]`로 나와야 합니다.

### 2. headless_args 설정

`codex --help`로 비대화형 플래그를 확인한 뒤 `config/routing-rules.yaml`을 수정합니다:

```yaml
codex:
  command: codex
  headless_args: ["--quiet"]   # 확인된 플래그로 교체
```

### 3. 핑 테스트 (선택)

```bash
./scripts/check-env.sh --ping-test
```

---

## 사용법

### Claude Code에서 자동 위임 (권장)

프로젝트 루트에서 Claude Code를 실행하면 `SKILL.md`를 읽고 자동으로 라우팅합니다:

```bash
claude
```

위임 가능한 작업 예시:
- "User 모델에 getter 추가해줘" → `boilerplate` → Codex 위임
- "이 함수들에 docstring 달아줘" → `docstring` → Codex 위임
- "JWT 로직 수정해줘" → `security-sensitive` → Claude Code 직접 처리

### 직접 실행

```bash
# 컨텍스트 파일 준비
cat > /tmp/ctx.md <<'EOF'
target file: src/user.py
function: get_user(id: int)
EOF

# 위임 실행 (결과: .router/results/task-001.md)
./scripts/delegate.sh boilerplate task-001 /tmp/ctx.md "add type hints"

# 검수
./scripts/verify.sh task-001

# 통계
./scripts/stats.sh
```

---

## 환경변수 오버라이드

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `CODEX_BIN` | `codex` (또는 rules의 command) | 백엔드 실행 파일 경로 |
| `RULES_FILE` | `config/routing-rules.yaml` | 규칙 파일 경로 |
| `TEMPLATES_DIR` | `templates/` | 핸드오프 템플릿 디렉토리 |
| `ROUTER_DIR` | `.router/` | 결과·로그 저장 디렉토리 |

---

## 테스트

```bash
bats tests/test_delegate.bats
```

shellcheck 검사:

```bash
shellcheck scripts/*.sh tests/fixtures/mock-codex
```

---

## 종료 코드 참조

| 코드 | 의미 |
|------|------|
| `0` | 성공 (`.router/results/<id>.md` 생성) |
| `2` | 인자 오류 |
| `3` | 규칙 파일 없음 또는 파싱 실패 → 위임 전면 비활성화 |
| `4` | task-type 위임 불가 (`never_delegate` 또는 `delegate_if` 미포함) |
| `5` | codex CLI 없음 |
| `6` | 실행 실패 (재시도 소진) |
| `7` | 타임아웃 (재시도 소진) |

---

## 토큰 절감 추정 방식

- **로컬 소비**: `(프롬프트 + 결과) 문자수 ÷ 4`
- **Claude 절감 추정**: `결과 문자수 × 3 ÷ 4`

결과물을 Claude가 직접 생성할 때 사고 토큰 포함 약 3배를 절감한다는 근사치입니다. `stats.sh`로 확인 가능합니다.

---

## 라이선스

MIT
