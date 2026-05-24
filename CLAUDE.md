# CLAUDE.md

LLM Orchestrator project. Short on purpose.

## Response shape

All replies use the Concise Agent Protocol. The canonical reference is [`concise-agent-protocol.md`](./concise-agent-protocol.md). The six shapes (Changed / Found / Blocked / Issues / Plan / Status) are defined there; do not duplicate them here.

## Working rules

- Short over long. If you can answer in one section, do.
- No preamble. The `Changed:` / `Found:` / `Plan:` header is the announcement.
- Verify before claiming done — run the command, paste the relevant line.
- Plan before non-trivial implementation. Use `/plan`.
- Use `/worktree` when work needs isolation.
- Use `/dispatch` to execute plan tasks; it routes to sequential or parallel based on independence.
- Use `/review` before declaring a feature complete.
- Use `/debug` when something is broken — root cause first, fix second.
- Use `/remember` when the user shares a fact that should survive the session.

## Skills

Skills live in `skills/<name>/SKILL.md`. Two-key frontmatter (`name`, `description`). Trigger conditions in `description`, starting with "Use when". Body short. No all-caps. No rationalization tables.

## Workspace

This repo *is* LLM Orchestrator. When editing here:
- Keep skill bodies under 200 lines.
- Add new skills only if not already covered.
- Update `AGENTS.md` and `architecture.md` when shape changes.
- Run `./tests/validate-skills.sh` before commits.
