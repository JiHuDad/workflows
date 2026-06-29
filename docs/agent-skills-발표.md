---
marp: true
title: agent-skills 도입 제안
description: AI 코딩 에이전트에 엔지니어링 규율을 — 팀 SDLC 통합
paginate: true
---

<!--
발표자 노트:
- 대상: 개발팀 전원 (Claude Code / Codex 사용자)
- 목표: addyosmani/agent-skills를 팀 SDLC에 도입하는 합의
- 소요: 약 15분 + Q&A
- 렌더링: `npx @marp-team/marp-cli docs/agent-skills-발표.md -o 발표.pdf`
-->

# agent-skills 도입 제안

### AI 코딩 에이전트에 **엔지니어링 규율**을 심다

팀 SDLC 통합 · 비용 라우터와의 시너지

<br>

> "확신에 찬 답이 옳은 답은 아니다."
> — agent-skills, doubt-driven-development

---

## 우리가 겪는 문제

AI는 코드를 **빠르게** 짜준다. 그런데…

- 📋 스펙 없이 바로 구현 — 무엇을 만드는지 합의가 없다
- 🧪 테스트를 건너뛴다 — "일단 동작하니까"
- 🔍 리뷰 없이 머지 — 결함이 프로덕션까지
- 🤖 **확신 ≠ 정확** — AI는 틀려도 자신만만하다

→ **속도는 얻었지만 품질·일관성을 잃는다.**
→ 사람이 매번 다 리뷰하면? 그 속도 이점이 사라진다.

---

## agent-skills 한눈에

| 항목 | 내용 |
|------|------|
| ⭐ Stars | **67.8k** (사실상 업계 레퍼런스) |
| 👤 저자 | Addy Osmani (Google Chrome 엔지니어링 리더) |
| 📜 라이선스 | MIT (자유 사용·수정) |
| 📦 구성 | **24 스킬 · 8 슬래시 커맨드 · 4 에이전트** |
| 📚 기반 | *Software Engineering at Google* 관행 |

> "production-grade engineering skills for AI coding agents"
> — 시니어 엔지니어의 판단을 **패키지화**한 것

---

## 핵심 1 — Process, not prose

스킬은 "설명서"가 아니라 **체크포인트가 있는 워크플로우**다.

```
발동 조건 → 단계별 절차 → 검증 게이트 → red flags
```

- AI가 읽고 "이해"하는 게 아니라 **따라야 하는 절차**
- 각 단계에 빠져나갈 수 없는 검증 관문(gate)
- "대충 넘어가기"가 구조적으로 차단됨

---

## 핵심 2 — 안티-합리화 (Anti-Rationalization)

AI가 일을 건너뛰려는 **핑계를 미리 봉쇄**한다.

| AI의 핑계 | 반박 (스킬에 내장) |
|-----------|-------------------|
| "확신하니까 검증 생략" | 확신은 새로운 문제에서 맹점을 가린다 |
| "이건 스킬 쓰기엔 너무 작아" | 항상 스킬부터 확인하라 |
| "리뷰는 마지막에 한 번에" | 늦은 발견 = 비싼 수정 |

→ 이게 agent-skills의 **진짜 차별점**. 규칙이 아니라 *강제력*.

---

## 핵심 3 — Progressive Disclosure = 토큰 절약

스킬은 깔려만 있고 **필요할 때만** 로드된다.

| 상태 | 토큰 |
|------|------|
| 세션 시작 (이름+설명 스캔) | 스킬당 **~100 토큰** |
| 활성화 시 | 본문 **< 5k 토큰** |
| **미활성 시** | **약 98% 절감** |

→ 수십 개 깔아도 무관한 작업엔 **비용 0에 가까움**
→ CLAUDE.md에 다 때려넣는 방식 대비 세션당 큰 절감

---

## SDLC 전 구간 커버

```
 /spec  →  /plan  →  /build  →  /test  →  /review  →  /ship
  정의      분해     점진 구현    검증      품질 게이트    배포
```

**4개 전문 에이전트** (병렬 리뷰):
`code-reviewer` · `test-engineer` · `security-auditor` · `web-performance-auditor`

> `/ship` 시 3개 에이전트가 **동시에** 리뷰 → 종합 (fan-out + merge)

---

## 왜 우리 팀에 필요한가

1. **품질 격차 해소** — 스펙·테스트·리뷰가 *선택*이 아닌 *기본값*
2. **일관성** — 누가 작업하든 같은 규율, 같은 산출물 구조
3. **온보딩** — 신규 팀원도 시니어의 워크플로우를 그대로 사용
4. **토큰 비용** — progressive disclosure로 컨텍스트 낭비 제거
5. **검증의 자동화** — 사람 리뷰를 **에이전트 반증**으로 대체·보강

---

## 우리 자산과의 시너지 ⚡

이미 우리에겐 **llm-task-router**가 있다 (비용 라우팅 + 검증 루프).

| 층 | 역할 | 출처 |
|----|------|------|
| **프로세스 층** | 무엇을·어떤 순서로·어떤 품질로 | agent-skills |
| **실행 층** | 각 단계를 싼 모델에 위임할지 판단 | 우리 router |

🎯 **결정적**: agent-skills의 `doubt-driven-development`가
우리가 이미 만든 `verify.sh` **반증 모드와 거의 일치**한다.
→ 우리는 이미 절반을 구현했다. 나머지를 흡수하면 된다.

---

## doubt-driven: 우리가 이미 가진 것

agent-skills의 반증 루프:
```
CLAIM → EXTRACT → DOUBT → RECONCILE → STOP
(결정 명명) (계약 추출) (적대적 리뷰) (분류)  (종료조건)
```
핵심 원칙: **"ARTIFACT + CONTRACT만 전달, CLAIM은 숨겨라"**
(리뷰어가 결론에 동조하지 않도록)

우리 `verify.sh`: 산출물을 최고 LLM이 반증 → `VERDICT: PASS/FAIL`
→ **개념 동일.** 이들의 정교함(CLAIM 은폐, 교차모델 리뷰)을 흡수하면 완성.

---

## 도입 방안 — 팀 SDLC 통합

**1단계 — 파일럿 (2주)**
핵심 3종만: `spec-driven-development` · `test-driven-development` · `code-review-and-quality`
→ 한 프로젝트에 적용, 효과 측정

**2단계 — 표준화**
팀 CLAUDE.md에 슬래시 커맨드 체계 통합, 코드리뷰 PR 템플릿 연동

**3단계 — 우리 router와 결합**
doubt-driven을 우리 검증 루프로 통합, 비용 라우팅과 품질 게이트 동시 운영

---

## 마이그레이션 로드맵 (→ prd.md)

| Phase | 가져올 것 | 우리 프로젝트 적응 |
|-------|----------|-------------------|
| A | SKILL.md **형식** (트리거/안티합리화/게이트) | 기존 SKILL.md 재작성 |
| B | `spec/plan/review` **슬래시 커맨드** | `/router:*`와 통합 |
| C | `doubt-driven-development` | 기존 `verify.sh` 업그레이드 |
| D | `code-review-and-quality` 등 품질 스킬 | 검증 백엔드에 연결 |

> 상세 범위·수용 기준·리스크는 **`prd.md`** 참조

---

## 다음 단계 (Call to Action)

1. ✅ 본 제안 **검토 및 파일럿 승인**
2. 📄 `prd.md` 기준 **마이그레이션 범위 확정**
3. 🚀 핵심 3종 스킬로 **2주 파일럿 시작**
4. 📊 파일럿 후 **효과 측정 → 전사 확대 결정**

<br>

### 핵심 메시지
> **AI의 속도 + 시니어의 규율**을 동시에.
> 우리는 이미 비용 라우터를 가졌다 — 여기에 품질 규율을 더하자.

---

## 참고 자료

- **레포**: github.com/addyosmani/agent-skills (MIT, 67.8k★)
- **설치**: `/plugin marketplace add addyosmani/agent-skills`
- **우리 프로젝트**: `llm-task-router` (이 레포)
- **마이그레이션 계획**: `prd.md`
- **검증 루프 설계**: `design.md` §6

질문 환영합니다 🙌
