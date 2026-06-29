# prd.md — agent-skills 마이그레이션

> **목적**: addyosmani/agent-skills(MIT, 67.8k★)의 일부를 `llm-task-router`에
> 마이그레이션하여, 팀 SDLC에 엔지니어링 규율을 통합한다.
> 발표 자료: `docs/agent-skills-발표.md`

---

## 1. 배경 (Background)

우리 `llm-task-router`는 **비용 라우팅 + 검증 루프**(생성=Codex, 검증=Claude)를
갖췄다. 그러나 다음이 비어 있다:

- 작업을 **언제·어떤 순서로** 진행할지에 대한 SDLC 규율 (spec→plan→build→…)
- AI의 회피를 막는 **안티-합리화** 강제력
- SKILL.md의 **표준 형식**(트리거/검증 게이트/red flags)

agent-skills는 이 공백을 정확히 메운다. 특히 `doubt-driven-development`는 우리가
이미 구현한 `verify.sh` 반증 모드와 **개념적으로 일치**하므로, 흡수 비용이 낮다.

### 1.1 핵심 통찰 — 두 층위는 상보적이다

| 층 | 책임 | 누가 |
|----|------|------|
| **프로세스 층** | 무엇을·어떤 순서로·어떤 품질 기준으로 | agent-skills (이식 대상) |
| **실행 층** | 각 단계의 기계적 작업을 싼 모델에 위임할지 판단 | llm-task-router (기존) |

→ 마이그레이션은 "프로세스 층"을 우리 프로젝트에 심되, **각 단계의 위임 가능
   step은 기존 router가 처리**하도록 연결하는 작업이다.

---

## 2. 목표 / 비목표 (Goals / Non-Goals)

### 2.1 목표

- **G1** agent-skills의 SKILL.md **형식**을 우리 SKILL.md에 이식 (트리거 매핑,
  안티-합리화 표, 검증 게이트, red flags)
- **G2** SDLC **슬래시 커맨드** 체계(`/spec`, `/plan`, `/review`)를 도입하되
  기존 `/router:*` 및 비용 라우팅과 통합
- **G3** `doubt-driven-development`의 정교한 절차(CLAIM→EXTRACT→DOUBT→RECONCILE→
  STOP, CLAIM 은폐)를 기존 `verify.sh` 반증 모드에 흡수·고도화
- **G4** 품질 스킬 1~2종(`code-review-and-quality`)을 우리 검증 백엔드에 연결
- **G5** 라이선스·출처 표기 준수 (MIT, NOTICE 명시)

### 2.2 비목표

- **NG1** agent-skills **24종 전체**를 그대로 복제하지 않는다 (정체성 희석)
- **NG2** 우리 프로젝트의 핵심 축(비용 라우팅)을 SDLC 축으로 **대체**하지 않는다
- **NG3** 웹 성능/브라우저 테스트 등 우리 범위 밖 스킬은 제외
- **NG4** addyosmani 플러그인을 런타임 의존성으로 묶지 않는다 (개념·형식만 이식)

---

## 3. 마이그레이션 범위 (Scope)

### 3.1 이식 대상 스킬 (선별)

| 스킬 | 이식 방식 | 우리 프로젝트 적응 |
|------|----------|-------------------|
| **spec-driven-development** | 형식 + 절차 | 우리는 이미 SPEC→plan→design 운영 중 → 스킬로 정식화 |
| **planning-and-task-breakdown** | 절차 | 위임 가능 step 식별 단계를 plan에 포함 |
| **doubt-driven-development** | 절차 고도화 | 기존 `verify.sh` adversarial 모드 업그레이드 |
| **code-review-and-quality** | 체크리스트 | 검증 백엔드(reviewer)에 리뷰 기준 주입 |
| **git-workflow-and-versioning** | 관행 | 커밋/브랜치 규약을 SKILL.md에 명문화 |

> 나머지 19종은 **비목표(NG1)**. 필요 시 후속 PRD에서 재검토.

### 3.2 제외 (명시)

- frontend-ui-engineering, browser-testing-with-devtools, performance-optimization,
  observability-and-instrumentation — 현재 우리 범위(코드 위임 라우팅) 밖

---

## 4. 단계별 계획 (Phased Plan)

### Phase A — 형식 이식 (저위험, 선행)

- `SKILL.md`를 agent-skills 골격으로 재작성:
  - frontmatter: 정밀한 트리거 description
  - **트리거 구문 매핑** 표 ("~추가해줘" → boilerplate 등)
  - **안티-합리화** 표 ("위임하기엔 사소해" → 거부)
  - **red flags** / 검증 게이트
- 코드 변경 없음. 라우팅 정확도·일관성 향상.

### Phase B — 슬래시 커맨드 통합

- `.claude/commands/` 추가: `/spec`, `/plan`, `/review`
- 기존 구상(`/router:stats`, `/router:dry-run`)과 네이밍 정합
- `/review`는 우리 `verify.sh`(반증)를 호출하도록 연결

### Phase C — doubt-driven 고도화

기존 `verify.sh` adversarial 모드를 다음으로 강화:
- **CLAIM 은폐**: 반증 프롬프트에 "생성자의 결론/주장"을 제외하고
  **산출물 + 원본 계약만** 전달 (현재 이미 prompts/result 분리 → 확장 용이)
- **분류 체계**: 발견을 `contract-misread > actionable > trade-off > noise`로 등급화
- **종료 조건**: 최대 3사이클 또는 trivial-only에서 정지 (무한 반증 방지)
- **교차 모델 옵션**: 다른 모델로 2차 반증 (interactive 시 제안, non-interactive 시 고지)

### Phase D — 품질 스킬 연결

- `code-review-and-quality` 체크리스트를 `templates/handoff-review.md`에 반영
- reviewer가 표준 리뷰 기준(가독성·테스트·경계조건)으로 반증하도록 고도화

---

## 5. 수용 기준 (Acceptance Criteria)

- [ ] **A1** SKILL.md에 트리거 매핑·안티-합리화·red flags 표가 존재
- [ ] **A2** `/spec`, `/plan`, `/review` 커맨드가 동작하고 README에 사용법 명시
- [ ] **A3** `verify.sh` 반증이 CLAIM 은폐 + 종료 조건(≤3 cycle)으로 동작
- [ ] **A4** 반증 발견이 4등급으로 분류되어 로그에 기록됨
- [ ] **A5** `NOTICE` 파일에 agent-skills 출처·MIT 라이선스 표기
- [ ] **A6** bats 전체 통과, shellcheck 무경고 (기존 품질 기준 유지)
- [ ] **A7** 파일럿 프로젝트 1건에서 spec→delegate→doubt-verify→review 시연

---

## 6. 라이선스 / 귀속 (Licensing)

- agent-skills는 **MIT**. 코드·텍스트 차용 시 원저작권 표기 의무.
- 루트에 `NOTICE` 추가: 차용한 스킬명, 원 저장소 URL, MIT 전문 링크.
- 직접 복제가 아닌 **개념·형식 기반 재작성**을 기본으로 하여 의존·혼동 최소화.

---

## 7. 리스크 (Risks)

| 리스크 | 영향 | 완화 |
|--------|------|------|
| 범위 확장으로 정체성 희석 | 중 | NG1/NG2로 선별 이식, 비용 축 유지 |
| 슬래시 커맨드 네이밍 충돌 | 저 | `/router:*` 네임스페이스 정합 |
| 반증 고도화로 검증 비용↑ | 중 | 종료조건(≤3 cycle) + tier 차등 유지 |
| upstream 변경 추적 부담 | 저 | 복제 아닌 재작성 → 디커플링 |

---

## 8. 오픈 퀘스천 (Open Questions)

- **Q1** 슬래시 커맨드를 `/spec`로 둘지 `/router:spec`로 네임스페이스화할지?
- **Q2** 교차 모델 반증(Phase C)에 어떤 2차 모델을 쓸지? (비용/가용성)
- **Q3** 파일럿 대상 프로젝트와 성공 지표(위임률·반증 차단율·재작업률)?
- **Q4** Phase D 품질 스킬을 1종(code-review)만 할지 2종(+security)까지 할지?

---

## 9. 승인 요청

이 PRD에 동의하시면 **"승인"**. Phase A(형식 이식)부터 착수합니다.
범위 조정이 필요하면 §3 표와 §8 오픈 퀘스천 기준으로 알려주세요.
