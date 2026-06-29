# plan.md — llm-task-router 구현 계획

> SDD 승인 게이트 #1: 사용자 승인 후 design.md 작성으로 진행

## 현재 상태

- 브랜치: `claude/llm-task-router-spec-1q52tc`
- SPEC.md 커밋 완료
- Phase 1 (core) 구현 준비 중

---

## Phase별 범위 및 순서

### Phase 1 — core (현재 대상)

**목표**: routing-rules.yaml + delegate.sh + check-env.sh + mock-cline 기반 테스트로 end-to-end 위임 1건 성공

**산출물**:
| 파일 | 요구사항 | 비고 |
|------|----------|------|
| `config/routing-rules.yaml` | R1 | 위임 조건 선언, 파일 없으면 위임 전면 비활성화 |
| `scripts/delegate.sh` | R2 | cline CLI 래퍼, 타임아웃·재시도, 결과 저장 |
| `scripts/verify.sh` | R2 지원 | diff 확인 / 테스트 실행 |
| `scripts/check-env.sh` | R5 | cline 설치·인증·모델 핑 |
| `scripts/stats.sh` | R4 지원 | log.jsonl 집계 |
| `templates/handoff-codegen.md` | R2 | 코드 생성 핸드오프 템플릿 |
| `templates/handoff-test-stub.md` | R2 | 테스트 스텁 템플릿 |
| `templates/handoff-docs.md` | R2 | 문서/주석 생성 템플릿 |
| `templates/handoff-transform.md` | R2 | 기계적 변환 템플릿 |
| `tests/fixtures/mock-cline` | R2 | cline mock 실행파일 |
| `tests/test_delegate.bats` | R2 | bats 단위 테스트 |
| `.gitignore` | — | .router/ 제외 |

**수용 기준 (Phase 1)** — 2026-06-12 전체 충족:
- [x] `config/routing-rules.yaml` 없을 때 delegate.sh가 0이 아닌 종료 코드 반환 (exit 3)
- [x] mock-cline으로 위임 1건 end-to-end: 결과 파일이 `.router/results/<task-id>.md`에 생성됨
- [x] 타임아웃(1초 이내) mock으로 타임아웃 처리 경로 확인 (exit 7, error:timeout 로깅)
- [x] cline 미설치 시 check-env.sh가 명확한 안내 출력
- [x] bats 테스트 전체 통과 (14/14)
- [x] shellcheck 경고 없음

### Phase 2 — cline 연동 (다음)

- 실제 cline CLI 연동 (Q2 해결 후)
- 타임아웃·재시도 실제 검증
- R4 토큰 로깅 완성

### Phase 3 — skill/플러그인화

- R3 SKILL.md
- `.claude-plugin/plugin.json`
- README.md (한국어+영어)
- 더미 프로젝트에서 전체 시나리오 검증

### Phase 4 — P1

- R6 사용자 정의 템플릿 디렉토리
- R7 verify.sh 테스트 자동 탐지
- R8 `/router:stats`, `/router:dry-run` 커맨드

### Phase 5 — 검증 루프 (doubt-driven verification) ★ 신규

비대칭 구조: **생성=Codex(싼 모델), 검증=Claude(최고 모델)**. 비용 라우팅의
품질 위험을 사람 리뷰가 아니라 최고 LLM의 반증으로 차단. (design.md §6)

| 산출물 | 내용 |
|--------|------|
| `routing-rules.yaml` | `reviewer`(claude) 백엔드, `verification_tier`, `escalation` 추가 |
| `verify.sh` | adversarial 모드: task_type 역참조 → 반증 의뢰 → VERDICT 파싱 |
| `templates/handoff-review.md` | doubt-driven 반증 프롬프트 |
| `delegate.sh` | 조립 프롬프트를 `.router/prompts/<id>.md`에 저장 (검증 컨텍스트) |
| `tests/fixtures/mock-reviewer` | VERDICT PASS/FAIL mock |
| `SKILL.md` | 검증 단계·escalation 분기 명문화 |

**수용 기준 (Phase 5)**:
- [ ] adversarial 등급 task-type 위임 시 reviewer가 호출되고 VERDICT로 pass/fail 판정
- [ ] VERDICT: FAIL → `fail:doubt` 로깅 + 비제로 종료 → escalation 신호
- [ ] VERDICT 라인 없으면 안전 기본값 `fail:doubt`
- [ ] mechanical 등급은 reviewer 미호출 (불필요한 비용 없음)
- [ ] reviewer 미설치 시 명확한 안내
- [ ] bats 전체 통과, shellcheck 무경고

---

## 열린 질문 처리 계획

| 질문 | 처리 시점 | 방법 |
|------|----------|------|
| Q1: 폐쇄망 cline auth | Phase 2 시작 전 | check-env.sh 실측 후 사용자 확인 |
| Q2: cline 헤드리스 플래그 | Phase 1 완료 후 | cline --version 확인, delegate.sh 주석에 플래그 옵션 문서화 |
| Q3: 레포 공개 범위 | Phase 3 전 | 사용자 결정 대기 |

---

## 기술적 결정 사항

1. **yq 의존성**: routing-rules.yaml 파싱에 `yq` 사용. 미설치 시 check-env.sh가 감지하고 설치 안내
2. **bats-core**: 테스트 프레임워크. 미설치 시 README에 설치 안내 (brew/apt)
3. **토큰 추정 방식**: `문자수 ÷ 4` (Claude 토크나이저 근사). README에 명시
4. **백엔드 추상화**: delegate.sh 내 `run_backend()` 함수로 cline 호출 격리 → P2에서 Codex 어댑터 교체 지점

---

## 승인 요청

이 plan.md에 동의하시면 **"승인"** 이라고 답해주세요. 그러면 design.md를 작성한 뒤 Phase 1 구현을 시작하겠습니다.

수정이 필요하면 변경할 항목을 알려주세요.
