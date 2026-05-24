# AGENTS.md

This project uses LLM Orchestrator's subagent roles. When a coding agent dispatches a subagent here, it uses one of these:

| Role               | Purpose                                                                 |
|--------------------|--------------------------------------------------------------------------|
| orch-implementer   | Executes one task from a plan. Returns a `Status:` block.               |
| orch-spec-reviewer | Stage 1 review: does the diff match the spec?                           |
| orch-code-reviewer | Stage 2 review: is the code correct, safe, idiomatic, minimal?          |
| orch-explorer      | Read-only codebase scout. Returns `file:line` refs.                     |
| orch-debugger      | Root-cause investigator. Diagnoses; does not fix.                       |
| orch-brainstormer  | Open-design explorer. Writes a spec file.                               |

Each subagent returns exactly one Status from this set:
- `DONE` — task complete, verified.
- `DONE_WITH_CONCERNS` — complete but flagged issues; see `Concerns:` block.
- `BLOCKED` — cannot proceed; see `Need:` block.
- `NEEDS_CONTEXT` — missing info; see `Ask:` block.

The orchestrator routes by Status, not by parsing prose.
