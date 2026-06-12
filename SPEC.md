# SPEC: llm-task-router — 하이브리드 LLM 태스크 라우팅 툴킷

> 이 문서를 Claude Code에 그대로 붙여넣고 "이 SPEC에 따라 진행해줘"라고 지시한다.
> SDD 워크플로우를 따른다: 본 SPEC 검토 → plan.md 작성 → 사용자 승인 → design.md 작성 → 사용자 승인 → 구현.

---

## 0. 작업 지시 (Claude Code 수행 절차)

1. `gh repo create llm-task-router --private --clone` 으로 GitHub 레포를 생성하고 클론한다. (gh CLI 미인증 시 사용자에게 `gh auth login`을 요청하고 대기)
2. 본 SPEC.md를 레포 루트에 커밋한다.
3. Phase 단위로 브랜치를 만들고(`phase/1-core`, `phase/2-cline`, ...) 각 Phase 완료 시 PR을 생성한다.
4. 각 Phase 시작 전 plan.md를 갱신하고 사용자 승인을 받는다. 승인 없이 다음 Phase로 넘어가지 않는다.
5. 모든 커밋 메시지는 Conventional Commits 형식을 따른다.

## 1. 문제 정의

Claude Code(고성능·고비용)와 Cline에 등록된 로컬 모델(저성능·초저비용, Cline을 통해서만 접근 가능, MCP/직접 API 불가)을 함께 쓰고 있다. 모든 작업을 Claude Code가 직접 수행하면 토큰 비용이 과도하고, 로컬 모델에 작업을 맡기려 해도 위임 판단·핸드오프·검수 체계가 없어 활용하지 못한다. 라우팅 판단은 강한 모델(Claude Code)이 하고, 검증이 싼 대량 생성 작업은 저비용 모델이 수행하는 재사용 가능한 툴킷이 필요하다.

## 2. 목표 (Goals)

- G1. Claude Code가 오케스트레이터로서 작업을 분해하고, 사전 정의된 **기계적 라우팅 기준**에 따라 위임 여부를 결정한다.
- G2. 위임 작업은 Cline CLI(헤드리스)를 통해 로컬 모델로 실행되고, 결과가 자동 회수·검수된다.
- G3. 위임된 작업의 토큰 절감량을 실측 로깅한다 (Claude 직접 수행 추정치 대비).
- G4. Claude Code 플러그인 형태로 패키징하여 `claude plugin add` 또는 레포 클론만으로 다른 프로젝트/다른 사용자가 즉시 사용 가능하다.
- G5. 폐쇄망 환경에서 동작한다 (외부 네트워크 의존성은 설치 시점에만 허용, 런타임에는 불필요).

## 3. 비목표 (Non-Goals)

- NG1. Cline 내부 개조 또는 Cline provider 추가 — Cline CLI를 블랙박스 외부 프로세스로만 사용한다.
- NG2. 로컬 모델 품질 개선(파인튜닝, 프롬프트 최적화 자동화) — v1은 핸드오프 템플릿 고정으로 충분.
- NG3. Codex 연동 — P2로 미룬다. 인터페이스만 확장 가능하게 설계한다.
- NG4. GUI/대시보드 — 로그는 JSONL 파일과 요약 스크립트로 충분.
- NG5. 멀티 로컬 모델 라우팅 — v1은 단일 위임 백엔드(Cline CLI)만 지원.

## 4. 아키텍처

```
Claude Code (오케스트레이터)
 │  SKILL.md: 라우팅 기준 + 핸드오프 템플릿 로드
 │
 ├─[위임 판정: 기준 충족]──▶ scripts/delegate.sh
 │                            ├─ 핸드오프 프롬프트 조립 (templates/*.md)
 │                            ├─ cline 헤드리스 실행 (타임아웃, 재시도 1회)
 │                            ├─ 결과 회수 → .router/results/<task-id>.md
 │                            └─ 토큰 로그 → .router/log.jsonl
 │
 ├─[검수]── diff/테스트 통과 확인. 실패 시 1회 재위임, 재실패 시 직접 수행
 │
 └─[위임 판정: 기준 미달]──▶ Claude Code 직접 수행
```

핵심 설계 원칙: **위임 여부는 휴리스틱("어려운가?")이 아니라 routing-rules.yaml의 기계적 조건으로 결정한다.** 판단 모호성을 제거해야 약한 모델 활용이 안정된다.

## 5. 레포 구조

```
llm-task-router/
├── SPEC.md                      # 본 문서
├── plan.md / design.md          # SDD 승인 게이트 산출물
├── README.md                    # 설치·사용법 (한국어+영어)
├── .claude-plugin/plugin.json   # Claude Code 플러그인 매니페스트
├── skills/
│   └── task-routing/SKILL.md    # 라우팅 기준·위임 절차·검수 절차
├── config/
│   └── routing-rules.yaml       # 위임 조건 (사용자 커스터마이즈 지점)
├── templates/
│   ├── handoff-codegen.md       # 코드 생성 핸드오프 템플릿
│   ├── handoff-test-stub.md     # 테스트 스텁
│   ├── handoff-docs.md          # 문서/주석 생성
│   └── handoff-transform.md     # 기계적 변환 (포맷, 마이그레이션)
├── scripts/
│   ├── delegate.sh              # Cline CLI 실행 래퍼 (핵심)
│   ├── verify.sh                # 검수: 테스트 실행 / diff 요약
│   ├── stats.sh                 # log.jsonl 집계 → 절감량 리포트
│   └── check-env.sh             # cline CLI 존재·인증·모델 응답 사전 점검
├── tests/
│   ├── test_delegate.bats       # delegate.sh 단위 테스트 (cline mock 사용)
│   └── fixtures/mock-cline      # cline을 흉내내는 mock 실행파일
└── .router/                     # 런타임 산출물 (gitignore)
    ├── results/
    └── log.jsonl
```

## 6. 요구사항

### P0 (Must-Have)

**R1. routing-rules.yaml** — 위임 조건을 선언적으로 정의:
```yaml
delegate_if:
  task_type: [boilerplate, test-stub, docstring, format-transform, classification]
  max_files_touched: 2
  spec_change: false
  verification: [tests-exist, diff-only]   # 검증 수단이 있어야만 위임
never_delegate:
  - security-sensitive    # 인증/암호화/입력검증 코드
  - architecture-change
  - cross-module-refactor
limits:
  timeout_sec: 180
  max_retries: 1
  max_output_lines: 500
```
수용 기준: [ ] 규칙 파일 없으면 위임 전면 비활성화(안전 기본값) [ ] yaml 파싱 실패 시 명확한 에러와 함께 위임 중단

**R2. delegate.sh** — 핸드오프 조립 + Cline CLI 실행 래퍼:
- 입력: `delegate.sh <task-type> <task-id> <context-file> "<instruction>"`
- 템플릿에 instruction·대상 파일 경로·제약(수정 금지 영역, 출력 형식)을 주입해 단일 프롬프트 생성
- `cline` 헤드리스 모드로 실행, 타임아웃 시 kill 후 실패 처리
- stdout을 `.router/results/<task-id>.md`에 저장
- 수용 기준: [ ] Given cline 미설치 When 실행 Then 명확한 안내와 비제로 종료 [ ] Given 타임아웃 When 초과 Then 프로세스 정리 후 실패 기록 [ ] mock-cline 기반 bats 테스트 통과

**R3. SKILL.md (task-routing)** — Claude Code의 행동 규약:
- 작업 수신 → routing-rules.yaml 대조 → 위임/직접 결정 → 위임 시 delegate.sh 호출 → verify.sh로 검수 → 실패 시 1회 재위임 → 재실패 시 직접 수행하고 사유를 log에 기록
- 수용 기준: [ ] 신규 프로젝트에서 플러그인 설치만으로 스킬이 트리거됨 [ ] never_delegate 항목은 어떤 경우에도 위임되지 않음

**R4. 토큰 로깅 (log.jsonl)** — 레코드: `{task_id, type, route(delegated|direct|fallback), local_tokens_est, claude_tokens_saved_est, verify_result, retries, duration_sec, ts}`
- 수용 기준: [ ] stats.sh가 위임률·검수통과율·추정 절감 토큰을 출력 [ ] 추정 방식(문자수/4 등)을 README에 명시

**R5. check-env.sh** — cline 설치·인증·모델 1회 핑 테스트. 폐쇄망에서 인증이 막히는 경우를 감지하고 대안(Cline SDK 래퍼, R-P2 참고)을 안내.

### P1 (Nice-to-Have)

- R6. 핸드오프 템플릿 4종 외 사용자 정의 템플릿 디렉토리 지원
- R7. verify.sh의 테스트 자동 탐지 (pytest/jest/ctest 감지 후 해당 파일만 실행)
- R8. `/router:stats`, `/router:dry-run`(위임 판정만 출력) 커맨드

### P2 (Future)

- R9. Codex 백엔드 어댑터 (`backend: codex` 설정 시 codex exec 사용) — delegate.sh의 백엔드 호출부를 함수로 분리해 둘 것
- R10. Cline CLI 불가 환경용 Cline SDK 기반 위임 래퍼
- R11. 라우팅 결과 피드백 루프 (검수 실패율 높은 task_type 자동 비활성화)

## 7. 성공 지표

- 2주 운용 시 위임 가능 유형 작업의 위임률 ≥ 70%
- 위임 작업 검수 통과율(1회차) ≥ 60% — 미달 시 해당 task_type을 routing-rules에서 제외하는 것이 올바른 대응임을 README에 명시
- 추정 토큰 절감 ≥ 30% (위임 대상 작업 한정, stats.sh 기준)

## 8. 개발 Phase

- **Phase 1 (core)**: R1, R2, R5 + mock-cline 테스트. 산출물: 로컬에서 mock으로 위임 1건 end-to-end 성공
- **Phase 2 (cline 연동)**: 실제 cline CLI 연동 검증, 타임아웃·재시도, R4 로깅
- **Phase 3 (skill/플러그인화)**: R3 SKILL.md, plugin.json, README, 신규 더미 프로젝트에서 설치 → 위임 → 검수 전체 시나리오 검증
- **Phase 4 (P1)**: R6–R8

각 Phase는 PR 단위로 종료하고, PR 본문에 수용 기준 체크리스트를 포함한다.

## 9. 열린 질문 (구현 전 사용자 확인 필요)

- Q1 [블로킹]: 폐쇄망에서 `cline auth` 통과 여부 — Phase 2 시작 전 check-env.sh로 실측. 불가 시 R10을 P0로 승격할지 결정
- Q2: Cline 헤드리스 호출의 정확한 비대화형 플래그/출력 형식 — Phase 1에서 cline CLI 버전 확인 후 delegate.sh에 반영 (버전별 분기 가능성 있음)
- Q3: 레포 공개 범위 — 사내 공유 목적이면 private + 사내 미러, 커뮤니티 공개면 라이선스(Apache-2.0 제안) 결정

## 10. 제약

- 런타임 외부 네트워크 호출 금지 (폐쇄망 호환)
- bash + yq/jq만 사용 (Python 의존 최소화; 불가피하면 stdlib만)
- 모든 스크립트는 `set -euo pipefail`, shellcheck 통과
