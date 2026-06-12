# llm-task-router

단순·반복 작업을 Codex CLI에 위임하는 하이브리드 LLM 라우팅 툴킷.

## 라우팅 규칙

**작업을 받으면 항상 먼저 SKILL.md를 읽고** 위임 여부를 판단하세요.

- 위임 가능 → `scripts/delegate.sh` 실행
- 직접 처리 → 평소대로 응답

## 핵심 명령

```bash
scripts/delegate.sh <task-type> <task-id> <context-file> "<instruction>"
scripts/verify.sh <task-id> [test-command]
scripts/stats.sh
scripts/check-env.sh          # 최초 설정 확인용
```

## 설정 파일

- `config/routing-rules.yaml` — 위임 조건, 백엔드 설정
- `templates/handoff-*.md` — Codex에 전달하는 프롬프트 템플릿

## 결과물 위치

- `.router/results/<task-id>.md` — 위임 결과
- `.router/log.jsonl` — 라우팅 이력 (append-only)
