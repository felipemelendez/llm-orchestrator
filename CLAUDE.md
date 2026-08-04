# CLAUDE.md

LLM Orchestrator project. Short on purpose.

## Response shape

All replies use the Concise Agent Protocol. The canonical reference is [`concise-agent-protocol.md`](./concise-agent-protocol.md). The six shapes (Changed / Found / Blocked / Issues / Plan / Status) are defined there; do not duplicate them here.

## Working rules

- Short over long. If you can answer in one section, do.
- No preamble. The `Changed:` / `Found:` / `Plan:` header is the announcement.
- Verify before claiming done — run the command, paste the relevant line.
- Non-trivial work runs through the plugin's process: plan before building (`/llm-orchestrator:plan`), root cause before fixing (`/llm-orchestrator:debug`), review before calling it complete (`/llm-orchestrator:review`). The rest of the catalog — worktrees, dispatch, memory, handoff — is in context already; each command and skill description says when it applies.

## Skills

Skills live in `skills/<name>/SKILL.md`. Two-key frontmatter (`name`, `description`). Trigger conditions in `description`, starting with "Use when". Body short. No all-caps. No rationalization tables.

## Workspace

This repo *is* LLM Orchestrator. When editing here:
- Keep skill bodies under 250 lines (target 150). `tests/validate-skills.sh` enforces the 250.
- Add new skills only if not already covered.
- Update `AGENTS.md` and `ARCHITECTURE.md` when shape changes.
- Run `./tests/validate-skills.sh` before commits.
