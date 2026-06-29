# llm-task-router — Claude Code 라우팅 스킬

이 스킬은 Claude Code가 단순·반복 작업을 Codex CLI에 자동 위임하도록 안내합니다.

## 위임 판단 기준

다음 조건이 **모두** 충족될 때 위임하세요:

1. 아래 `delegate_if` 목록에 해당하는 task-type인 경우
2. `never_delegate` 목록에 없는 경우
3. 수정 파일이 2개 이하인 경우
4. 사양(SPEC) 변경이 없는 순수 코드 생성·변환인 경우

### delegate_if (위임 가능 task-type)

| task-type | 사용 시점 |
|-----------|----------|
| `boilerplate` | 반복적 코드 생성 (CRUD, DTO, 설정 파일, getter/setter 등) |
| `test-stub` | 테스트 스텁·픽스처 생성 (로직 없는 뼈대) |
| `docstring` | 함수·클래스 문서화 (기존 코드 변경 없음) |
| `format-transform` | 기계적 형식 변환 (JSON↔YAML, 탭→스페이스, 인코딩 등) |
| `classification` | 입력 분류·태깅 (패턴 매칭 수준) |

### never_delegate (직접 처리 필수)

- `security-sensitive` — 인증·암호화·입력검증·권한 코드
- `architecture-change` — 모듈 구조·인터페이스 재설계
- `cross-module-refactor` — 여러 모듈에 걸친 리팩터링

---

## 위임 실행 방법

```bash
scripts/delegate.sh <task-type> <task-id> <context-file> "<instruction>"
```

### 인자 설명

| 인자 | 형식 | 설명 |
|------|------|------|
| `task-type` | 위 표의 값 | 작업 유형 |
| `task-id` | `[A-Za-z0-9._-]+` | 고유 식별자 (예: `feat-add-types-001`) |
| `context-file` | 파일 경로 | 대상 파일 경로, 함수 시그니처 등 컨텍스트 |
| `instruction` | 문자열 | Codex에게 전달할 작업 지시 |

### context-file 작성 요령

```
target file: src/user.py
function: get_user(user_id: int) -> Optional[User]
existing code: (생략 또는 스니펫)
constraint: type hints 추가, 로직 변경 금지
```

### 실행 예시

```bash
# 컨텍스트 파일 작성
cat > /tmp/ctx.md <<'EOF'
target file: src/models/user.py
class: User
fields: id, name, email, created_at
EOF

# 위임 실행
scripts/delegate.sh boilerplate task-001 /tmp/ctx.md \
  "add __repr__ and __eq__ methods to User class"
```

---

## 결과 처리 절차

1. **종료 코드 확인**

   | 코드 | 의미 | 처리 |
   |------|------|------|
   | `0` | 성공 | stdout에서 결과 파일 경로 읽기 |
   | `3` | 규칙 파일 없음 | 직접 처리 |
   | `4` | 위임 불가 task-type | 직접 처리 |
   | `5` | codex CLI 없음 | `check-env.sh` 실행 후 사용자 안내 |
   | `6` | 실행 실패 | 직접 처리 |
   | `7` | 타임아웃 | 직접 처리 또는 재시도 |

2. **결과 파일 읽기** (exit 0인 경우)

   ```bash
   RESULT_FILE=$(scripts/delegate.sh boilerplate t-001 /tmp/ctx.md "...")
   cat "$RESULT_FILE"   # 코드 블록 추출
   ```

3. **검수 실행 (생성=싼 모델, 검증=최고 모델)**

   위임 결과는 **무조건 검수**한다. 검증 등급은 `routing-rules.yaml`의
   `verification_tier`가 task-type별로 결정한다:
   - `mechanical` (boilerplate, docstring, format-transform): 파일·길이·테스트만
   - `adversarial` (test-stub, classification): **최고 LLM(claude)이 doubt-driven
     반증** 수행 — "이 산출물이 틀렸다고 가정하고 결함을 찾아라"

   ```bash
   # 검수 (등급은 자동 결정. adversarial이면 reviewer LLM 호출)
   scripts/verify.sh t-001

   # 테스트 명령 포함
   scripts/verify.sh t-001 "pytest tests/test_user.py -q"
   ```

   **검수 결과 분기:**
   | verify.sh 종료 | 의미 | 처리 |
   |----------------|------|------|
   | `0` (pass) | 기계적 통과 + (해당 시) 반증 PASS | 결과 채택 |
   | `1` (fail:doubt) | 최고 LLM이 결함 발견 (VERDICT: FAIL) | **escalation** |
   | `1` (fail:tests/no-result) | 기계적 실패 | 직접 처리 |

4. **escalation — 반증 실패 시 직접 재작업**

   `verify.sh`가 `fail:doubt`로 실패하면 위임 결과를 **버리고**, stderr에 출력된
   결함 근거를 참고하여 **Claude Code가 직접** 작업을 다시 수행한다
   (`routing-rules.yaml`의 `escalation.on_fail: claude-direct`). 위임은 낙관적
   시도이고, 반증이 안전망이다.

5. **통계 확인**

   ```bash
   scripts/stats.sh
   ```

---

## 위임 판단 예시

### 위임 O

```
"User 모델에 __repr__ 추가해줘"
→ task-type: boilerplate, 파일 1개, 로직 없음 → 위임
```

```
"이 함수들에 전부 docstring 달아줘"
→ task-type: docstring, 코드 변경 없음 → 위임
```

```
"config.json을 config.yaml로 변환해줘"
→ task-type: format-transform → 위임
```

### 위임 X (직접 처리)

```
"JWT 검증 로직을 수정해줘"
→ security-sensitive → 직접 처리
```

```
"이 버그가 왜 발생하는지 추적해서 고쳐줘"
→ 복잡한 추론 필요, delegate_if 미해당 → 직접 처리
```

```
"서비스 레이어를 Repository 패턴으로 바꿔줘"
→ architecture-change → 직접 처리
```
