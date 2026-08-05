---
name: brainstorming
description: Use when starting creative work — a new feature, added functionality, a system design, or a behavior change — before any code is written. Not for one-line fixes, mechanical chores, or when an approved spec already exists.
---

# Brainstorming

Short, structured exploration that ends in a one-screen spec. The terminal state is `writing-plans`: when the spec is approved, invoke that and nothing else. Sliding from a design conversation into a UI, MCP, or framework skill skips the plan that every downstream gate assumes exists.

## Before spending questions

If the request bundles several independent subsystems — "a platform with chat, file storage, billing and analytics" — say so immediately and split it. Each sub-project gets its own spec, plan, and implementation cycle; refining an unsplit request wastes the questions and produces a spec nobody can execute.

**Research gate (Trigger A).** If the task names a library, framework, SDK, security-sensitive domain, or version-shaped token — or the UserPromptSubmit hook signalled research relevance — invoke `research-classifier` on the raw task text before asking anything. On `RESEARCH_NEEDED`, announce in one line, dispatch `orch-researcher` with the eight-field envelope in `templates/researcher-prompt.md` (it returns `BLOCKED` on a missing field), and wait: a `CONTRADICTED` brief changes the framing itself, and `VERIFIED`/`COULDN'T_VERIFY` findings sharpen the questions you're about to ask — which is why research runs first.

**Architecture grounding.** For a non-trivial change to an existing codebase, load the recorded decisions and treat them as spec constraints:

```bash
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
L=$(orch_lib orch-detect.sh) && . "$L" && orch_arch_cached "$PWD"
```

Also read `./CLAUDE.md`'s `## Decisions` and `## Conventions`. Acknowledge them in one line — "Honoring recorded decisions: offline-first via SQLite; data access through the repository layer" — so a stale decision gets caught by the user, not baked into the spec. This step is informational: no questions, no explorer dispatch, no per-task re-study of the codebase — that happened once at `/llm-orchestrator:onboard`. On a cache miss with nothing recorded, at most add one line suggesting that command, and move on.

## The conversation

Glance at the project first (`ls`, `README`, `CLAUDE.md`) so questions are specific. Ask at most ~3 questions, one per message, multiple choice where it fits, and stop the moment the picture is clear — a wall of questions is the thing this skill exists to prevent. Then propose two options (not four), each with a one-line summary and a one-line tradeoff, and mark a recommendation:

```
Found:
- <one-line restatement of the goal>
Options:
- A: <name> — <one-line tradeoff>
- B: <name> — <one-line tradeoff>
Recommendation:
- A, because <one line>
```

Wait for the user's choice before writing the spec. The choice is theirs.

## The spec

Save to `docs/llm-orchestrator/specs/YYYY-MM-DD-<slug>-spec.md` using `templates/spec.md` (Problem / Goals / Non-goals / Approach / Open questions). One screen; longer means the scope needs splitting. What goes wrong at this step:

- The format has no slot for error handling or testing, so those two get forgotten and then built badly — put both in `## Approach` explicitly.
- Fill `## Research` with the brief path, verdict, and notable findings — or "none — no research-relevant signals".
- Cut anything the Goals don't require. The downstream reviewer rejects work it can't trace to a Goal, so over-building here surfaces as rejected diffs later. Targeted cleanup of code the work must touch is in scope — the way a competent engineer improves code they're working in — but say so in the spec, so it traces.

Then re-read the spec cold: placeholders, TBDs, Goals without a testable success criterion, contradictions with recorded decisions, scope drift from what was asked. That inline pass is the primary review — a fresh-subagent round-trip on a document you just wrote costs minutes for marginal gain. Escalate to a fresh `orch-spec-reviewer` (prompt: `skills/brainstorming/spec-document-reviewer-prompt.md`, advisory verdict, cap 3 iterations) only when the spec is high-stakes: security-sensitive, irreversible migration, public API.

Hand off to `writing-plans`.

## Visual companion (optional)

When upcoming questions are genuinely spatial — wireframes, diagrams, side-by-side layouts — offer the browser visual panel once, in its own message, using the wording in `visual-companion.md`; if accepted, read `skills/brainstorming/visual-companion.md` and follow the loop there. A UI topic is not automatically a visual question, and the offer is never repeated in a session.
