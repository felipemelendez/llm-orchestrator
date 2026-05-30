---
revision: 1  # integer; increment by 1 every time this artifact is regenerated
last_regenerated_at: 2026-01-01T00:00:00Z  # ISO8601 UTC timestamp; set to wall-clock time at regeneration
trigger: user  # one of: user | threshold | tier-boundary
context_estimate_pct: unknown  # integer 0-100 representing fill level of the context window, or the literal unknown
slug: my-task-slug  # kebab-case identifier matching the plan filename (e.g. ble-test-infra)
plan: docs/llm-orchestrator/plans/YYYY-MM-DD-{{slug}}-plan.md  # path to the active plan file
spec: docs/llm-orchestrator/specs/YYYY-MM-DD-{{slug}}-spec.md  # path to the spec file, or "n/a" if no spec exists
---

# Handoff: {{slug — replace with the human-readable task title}}

<!-- purpose: Title line. Replace {{slug}} above with the task title. Keep it short — this is the artifact identifier, not a description. -->

**Status:** Mid-flight. The previous agent ran low on context. Read this document top to bottom before touching any code or running any command.

## Mission carried over

<!-- purpose: paste the user's mandate word-for-word; do not paraphrase. Then add one sentence stating the quality bar the user set. This section must be copied verbatim from the original user request so the next controller knows exactly what was commissioned — paraphrasing introduces drift and scope creep. -->

{{user_mandate_verbatim — paste the user's exact words here, quoted if possible}}

Quality bar: {{quality_bar — one sentence describing the explicit standard the user set, e.g. "world-class, no shortcuts, all decisions backed by research"}}

## Memory index

<!-- purpose: Record SECTION NAMES and LINE RANGES, not just paths. This section is generated FROM reads of CLAUDE.md and ~/.llm-orchestrator/architecture/<hash>/decisions.md at regeneration time — it is not hand-written from memory. List every memory file under ~/.claude/projects/.../memory/ that is relevant to this task. If a file is missing from this index, the next controller will not know to read it and may violate a constraint. -->

**CLAUDE.md sections in scope:**
- `## Working rules` (lines {{start}}-{{end}}) — {{one-line summary of what constraint this imposes}}
- `## Skills` (lines {{start}}-{{end}}) — {{one-line summary}}

**Project memory files (read in this order before writing any code):**
- `{{~/.claude/projects/.../memory/file1.md}}` — {{what constraint or pitfall it documents}}
- `{{~/.claude/projects/.../memory/file2.md}}` — {{what constraint or pitfall it documents}}

**Architecture decisions (from `~/.llm-orchestrator/architecture/<hash>/decisions.md`):**
- `{{decision_key}}` — {{one-line statement of the decision and what it forbids}}

## Plan state

<!-- purpose: This section INDEXES the plan file's checkboxes (the durable source of truth) and TaskList (the in-flight source of truth). It never duplicates or contradicts them. At regeneration time: open the plan file, count checkboxes at the task-heading level (### N.), then cross-reference with TaskList output. Record exact counts. Do not summarise sub-step checkboxes here — they live in the plan file. -->

**Plan file:** `{{plan — same value as the frontmatter field}}`

**Current tier / task:** Tier {{N}}, Task {{M}} — {{task name}}

**Checkpoint counts (reconciled at regeneration):**
- Completed: {{N}} of {{total}} task-heading checkboxes ticked in the plan file
- In-flight: {{N}} tasks reported by TaskList as active
- Pending: {{N}} task-heading checkboxes still unticked

**Next action:** {{one sentence — the first thing the next controller does after verifying the baseline}}

## Active task context

<!-- purpose: Goal-conditioned context for the NEXT action only. Three sub-sections:
  1. Files in play — curate these against the immediate next task so the fresh controller
     doesn't re-discover them; this is the goal-conditioned file list. Include line ranges where known.
  2. Key technical concepts — frameworks/conventions/decisions active for THIS task that the
     fresh model would otherwise re-derive. Index by name against CLAUDE.md "## Conventions"
     and "## Decisions" sections — do NOT duplicate content, only reference it.
  3. Re-hydration pointer — one line stating where fuller prior context lives if this artifact
     proves insufficient. Keeping this a pointer (not a dump) keeps the artifact lean and
     avoids bloating it. -->

**Files in play for the next action** (touch these first to execute the `Next action` above):

| Path | Lines | Why |
|------|-------|-----|
| `{{path/to/file1}}` | {{L1–L2}} | {{what the next action does here}} |
| `{{path/to/file2}}` | {{L1–L2}} | {{what the next action does here}} |
| `{{path/to/file3}}` | — | {{new file / full replacement}} |

**Key technical concepts in play:**

- `{{ConceptOrDecisionName}}` — {{one sentence on why it matters for the next action; see CLAUDE.md `## {{SectionName}}` for the authoritative definition}}
- `{{ConceptOrDecisionName}}` — {{one sentence; cross-reference the architecture decision or memory file by name, do not repeat its content}}

**Re-hydration pointer:**

If this artifact proves insufficient, the full prior context lives in: (1) `git log -p <path-to-this-handoff-artifact>` — every prior version of this artifact is in git history; (2) the prior session transcript linked from the plan file's `## Session log` section.

## Recent agent reports

<!-- purpose: paste the actual text the subagents produced — do NOT summarise. Copy the Status / Issues / Found blocks verbatim. The next controller needs the exact wording to judge whether a concern was addressed. Summaries lose the load-bearing detail. Include the last 3-5 blocks. -->

**Report 1 ({{agent_role}}, {{YYYY-MM-DD}}):**

```
{{paste verbatim Status / Issues / Found block}}
```

**Report 2 ({{agent_role}}, {{YYYY-MM-DD}}):**

```
{{paste verbatim Status / Issues / Found block}}
```

**Report 3 ({{agent_role}}, {{YYYY-MM-DD}}):**

```
{{paste verbatim Status / Issues / Found block}}
```

## In-flight observations

<!-- purpose: Record anything the controller noticed since the last regeneration that is not yet captured in the plan file — e.g. a review agent flagged an issue at a specific line and you addressed it but haven't closed the checkbox yet, or a deviation from the plan that was research-verified. These are ephemeral notes; once they're merged into the plan file or resolved, remove them. Each observation must have a file:line citation if it touches code. -->

- {{observation — file:line — what was noticed, what was done, what is still open}}

## Verification baseline

<!-- purpose: These are the exact commands the next controller runs FIRST, before writing a single line of code, to confirm the repo is in the expected green state. Include the expected output (test counts, typecheck exit lines) that were true at regeneration time. CRITICAL: if these commands do not produce the expected output on resume, the next controller must NOT proceed — it must invoke systematic-debugging on the divergence before touching any code. "Should pass" is not acceptable here; paste the actual line from the last successful run. -->

Run these in order before doing anything else. If any command diverges from the expected output, stop and debug before proceeding.

```bash
{{verify_command_1}}
```
Expected: `{{exact output line}}`

```bash
{{verify_command_2}}
```
Expected: `{{exact output line}}`

```bash
{{verify_command_3}}
```
Expected: `{{exact output line}}`

## Known gotchas

<!-- purpose: Document every failure path the prior controller hit, with the file:line where it manifested and the fix that resolved it. This section exists so the next controller does not rediscover the same pitfalls. If a pitfall has a workaround documented in a memory file, cite both the memory file and the file:line so the next controller can cross-reference. -->

- **{{gotcha title}}** (`{{file:line}}`): {{what happened}} — Fix: {{what resolved it}}
- **{{gotcha title}}** (`{{file:line}}`): {{what happened}} — Fix: {{what resolved it}}

## What NOT to do

<!-- purpose: Explicit guardrails specific to this work. These are not general project rules (those live in CLAUDE.md and memory files); these are constraints that emerged from this particular task and are not obvious from reading the codebase. Each entry must say what the forbidden action is AND why it is forbidden. -->

- Do not {{action}} — {{reason it breaks something specific to this task}}
- Do not {{action}} — {{reason}}

## Resume prompt

<!-- purpose: This is what the user pastes into a fresh session to resume work. It must be self-contained: the next controller gets no other context until it has read the files listed here. It must name this artifact's own path, the read-order memory files, and the plan file. It must END with the literal word Go. so the controller knows to begin immediately after reading. Do not add pleasantries or meta-commentary inside this block. -->

```
Read these files in order before doing anything else:

1. <path-to-this-handoff-artifact>  ← this artifact (the deployed artifact path for your project)
2. {{plan path from frontmatter}}
3. {{memory file 1 path}}
4. {{memory file 2 path}}

Context: {{one sentence describing what phase the work is in and what was last completed}}

Resume from: Tier {{N}}, Task {{M}} — {{task name}}.

First action: run the Verification baseline section commands and confirm green. Only proceed after green. If any baseline command diverges from the expected output, invoke systematic-debugging before touching any code.

Go.
```
