# AGENTS.md

Reference for the subagent roles (specialized agents that run orchestrator commands) and the Status values they return. Names below match the `subagent_type:` value the Task tool expects (the same as each file's frontmatter `name:` in `agents/`).

## House style

Every subagent in this project follows the Concise Agent Protocol. See [`concise-agent-protocol.md`](./concise-agent-protocol.md) for response shapes. The controller (the main agent you talk to, which routes work to subagents) reads Status blocks to decide what to do next.

Subagents:
- Reply in shape blocks, not paragraphs.
- Verify with a real command before claiming success.
- Never write to `main`/`master` without explicit user OK.
- Stop and return `Status: BLOCKED` rather than guess.

## Roles _(haiku = fastest/cheapest · sonnet = balanced · opus = most capable)_

| `subagent_type`        | Model  | Used by                | Purpose                                                          |
|------------------------|--------|------------------------|------------------------------------------------------------------|
| `orch-explorer`        | haiku  | `/plan`, `/debug`      | Read-only codebase search; returns file:line refs                |
| `orch-implementer`     | sonnet | `/dispatch`            | Executes one task from a plan; returns `Status:` block           |
| `orch-spec-reviewer`   | sonnet | `/review` stage 1      | "Does the diff match the spec/plan?"                             |
| `orch-code-reviewer`   | sonnet | `/review` stage 2      | "Is the code correct, safe, idiomatic?"                          |
| `orch-debugger`        | sonnet | `/debug`               | Root-cause investigation before any edit                         |
| `orch-brainstormer`    | opus   | brainstorming design stage | Open-design explorer; writes the spec                        |
| `orch-researcher`      | sonnet | research gate          | Verifies external APIs/versions against current docs; returns VERIFIED/COULDN'T_VERIFY/CONTRADICTED/NOT_APPLICABLE |
| `orch-security-reviewer` | sonnet | `/review` security pass | Checks diffs for common security issues (injection, auth, secrets, unsafe deps) |

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

## Commands

| Command | What it does |
|---------|--------------|
| `/llm-orchestrator:onboard` | One-time codebase study: maps architecture and conventions, proposes `## Decisions` + `## Conventions` for `./CLAUDE.md`, writes them on a single approval. Idempotent — skips if already onboarded. |
| `/llm-orchestrator:init` | Add LLM Orchestrator conventions to a project. |
| `/llm-orchestrator:plan` | Turn an approved spec into a checklist-shaped plan. |
| `/llm-orchestrator:worktree` | Create an isolated git worktree. |
| `/llm-orchestrator:dispatch` | Run a focused subagent with a constructed context envelope. |
| `/llm-orchestrator:review` | Two-stage review (spec + code quality), plus optional security pass. |
| `/llm-orchestrator:debug` | Root-cause debugging. |
| `/llm-orchestrator:verify` | Run tests/lint/typecheck and report evidence. |
| `/llm-orchestrator:finish` | Decide between merge / PR / keep / discard. |
| `/llm-orchestrator:remember` | Append a fact to project CLAUDE.md (or user CLAUDE.md / plugin research config), classified by section. |
| `/llm-orchestrator:forget` | Soft-delete matching lines from CLAUDE.md or plugin memory. |
| `/llm-orchestrator:handoff` | Regenerate the versioned context-handoff artifact for the current task and hand control to a fresh session. Fires automatically at tier seams; invoke manually when context strains. |

## Cross-harness

LLM Orchestrator ships Claude Code first. There are no Codex / Gemini / Copilot mirrors yet.
