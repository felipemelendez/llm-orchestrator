# AGENTS.md

Subagent roles used by LLM Orchestrator commands. Names below match the `subagent_type:` value the Task tool expects (the same as each file's frontmatter `name:` in `agents/`).

## House style

Every subagent in this project follows the Concise Agent Protocol. See [`concise-agent-protocol.md`](./concise-agent-protocol.md) for response shapes.

Subagents:
- Reply in shape blocks, not paragraphs.
- Verify with a real command before claiming success.
- Never write to `main`/`master` without explicit user OK.
- Stop and return `Status: BLOCKED` rather than guess.

## Roles

| `subagent_type`        | Model  | Used by                | Purpose                                                          |
|------------------------|--------|------------------------|------------------------------------------------------------------|
| `orch-explorer`        | haiku  | `/plan`, `/debug`      | Read-only codebase search; returns file:line refs                |
| `orch-implementer`     | sonnet | `/dispatch`            | Executes one task from a plan; returns `Status:` block           |
| `orch-spec-reviewer`   | sonnet | `/review` stage 1      | "Does the diff match the spec/plan?"                             |
| `orch-code-reviewer`   | sonnet | `/review` stage 2      | "Is the code correct, safe, idiomatic?"                          |
| `orch-debugger`        | sonnet | `/debug`               | Root-cause investigation before any edit                         |
| `orch-brainstormer`    | opus   | brainstorming design stage | Open-design explorer; writes the spec                        |
| `orch-researcher`      | sonnet | research gate          | Verifies external APIs/versions against current docs; returns VERIFIED/COULDN'T_VERIFY/CONTRADICTED/NOT_APPLICABLE |

Prompt templates live in `templates/`:
- `implementer-prompt.md`
- `spec-reviewer-prompt.md`
- `code-reviewer-prompt.md`
- `dispatch-prompt.md` (generic envelope)
- `dispatch-response.md` (status enum reference)

The native subagent definitions live in `agents/orch-*.md`.

## Status enum

Every subagent returns exactly one Status:

- `DONE` — task complete, verified.
- `DONE_WITH_CONCERNS` — complete but flagged issues; see `Concerns:` block.
- `BLOCKED` — cannot proceed; see `Need:` block.
- `NEEDS_CONTEXT` — missing info from the controller; see `Ask:` block.

Controllers route by Status, not by parsing prose.

## Cross-harness

LLM Orchestrator ships Claude Code first. Codex / Gemini / Copilot mirrors are tracked in [`roadmap.md`](./roadmap.md) and not yet shipped.
