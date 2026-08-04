# AGENTS.md

Reference for the subagent roles (specialized agents that run orchestrator commands) and the Status values they return. Names below match the `subagent_type:` value the Agent tool expects (the same as each file's frontmatter `name:` in `agents/`). The dispatch tool is `Agent`; `TaskCreate` manages the task list and dispatches nothing.

## House style

Every subagent in this project follows the Concise Agent Protocol. See [`concise-agent-protocol.md`](./concise-agent-protocol.md) for response shapes. The controller (the main agent you talk to, which routes work to subagents) reads Status blocks to decide what to do next.

Subagents:
- Reply in shape blocks, not paragraphs.
- Verify with a real command before claiming success.
- Never write to `main`/`master` without explicit user OK.
- Stop and return `Status: BLOCKED` rather than guess.

## Roles _(model = capability, chosen per role; effort inherits the session preference — see docs/anthropic-ecosystem.md for the table and the evidence)_

| `subagent_type`        | Model  | Used by                | Purpose                                                          |
|------------------------|--------|------------------------|------------------------------------------------------------------|
| `orch-explorer`        | fable  | `/llm-orchestrator:onboard`      | Read-only codebase search; returns `Found:` with file:line refs   |
| `orch-implementer`     | fable  | `/llm-orchestrator:dispatch`            | Executes one task from a plan; returns `Status:` block           |
| `orch-spec-reviewer`   | fable  | `/llm-orchestrator:review` stage 1      | "Does the diff match the spec/plan?"                             |
| `orch-code-reviewer`   | fable  | `/llm-orchestrator:review` stage 2      | "Is the code correct, safe, idiomatic?"                          |
| `orch-debugger`        | fable  | `/llm-orchestrator:debug` (dispatch it when the investigation is read-heavy; the command's default path runs `systematic-debugging` in-context) | Root-cause investigation before any edit; returns `Found:` |
| `orch-researcher`      | fable  | research gate          | Verifies external APIs/versions against current docs; returns VERIFIED/COULDN'T_VERIFY/CONTRADICTED/NOT_APPLICABLE |
| `orch-security-reviewer` | opus | `/llm-orchestrator:review` security pass | Checks diffs for common security issues (injection, auth, secrets, unsafe deps). Deliberately not Fable 5: its safety classifiers fire on benign security work |

Prompt templates live in `templates/`:
- `implementer-prompt.md`
- `spec-reviewer-prompt.md`
- `code-reviewer-prompt.md`
- `dispatch-prompt.md` (generic envelope)
- `dispatch-response.md` (status enum reference)

The native subagent definitions live in `agents/orch-*.md`.

When Claude Code's `Workflow` tool is available, these same subagents are dispatched from
workflow scripts via the `agentType` option (composed with a structured `schema`) — no new roles.
`workflows/review-diff.js` drives the two-stage review this way; see the `using-workflows` skill
for when a workflow is preferred over the inline markdown path.

## Status enum

The **implementer** returns exactly one Status block. The read-only agents do not: the explorer and debugger return `Found:`, the three reviewers return `Issues:` + `Verdict:`, and the researcher returns its own four-outcome Status (`VERIFIED` / `COULDN'T_VERIFY` / `CONTRADICTED` / `NOT_APPLICABLE`). Each agent's own file is the contract; this page used to claim all seven returned the enum below, which left a controller waiting on a `Status:` that five of them never emit.

The implementer's enum:

- `DONE` — task complete, verified. Requires a `Verify:` block with the command and its output; the SubagentStop grader rejects a DONE without one.
- `DONE_WITH_CONCERNS` — complete but flagged issues; see `Concerns:` block. Also requires `Verify:`.
- `PARTIAL` — a `Stop if:` condition fired mid-task; see `Progress:` / `Remaining:` blocks. The controller resumes or re-dispatches with the remainder — completed work is never redone.
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
| `/llm-orchestrator:research` | Verify a planned approach against current sources before building on it, and write a brief the human can read in 30 seconds. |
| `/llm-orchestrator:verify` | Run tests/lint/typecheck and report evidence. |
| `/llm-orchestrator:finish` | Decide between merge / PR / keep / discard. |
| `/llm-orchestrator:remember` | Append a fact to project CLAUDE.md (or user CLAUDE.md / plugin research config), classified by section. |
| `/llm-orchestrator:forget` | Soft-delete matching lines from CLAUDE.md or plugin memory. |
| `/llm-orchestrator:handoff` | Write a short handoff note for the current task so work resumes cleanly after the context is compacted. Invoke manually, or the nudge hook prompts you once when context crosses ~950K tokens. |
| `/llm-orchestrator:skills` | List the installed skills and commands with their trigger conditions — a one-screen catalog of what the plugin can do and when each fires. Optional keyword filter. |

## Cross-harness

LLM Orchestrator ships Claude Code first. The skills, commands, and agent prompts are plain markdown and work as guidance in any harness that can read them. The enforcement layer — the hooks in `hooks/hooks.json` (protocol grader, research gate, skill nudge, no-verify guard, destructive-git guard, handoff nudge, Status validator) — is Claude Code-specific and is not yet ported to Codex / Gemini / Copilot. In those harnesses you get the skills as instructions without the mechanical enforcement.
