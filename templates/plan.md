# <Title> — Plan

Date: YYYY-MM-DD
Spec: docs/llm-orchestrator/specs/YYYY-MM-DD-<slug>-spec.md

## Goal
- one line

## Files (overview)
- create: <path>
- modify: <path>:<line-range>
- test: <path>

## References

Sources the team verified before committing to this plan. Required when the spec's `## Research` section is non-empty; "none" otherwise.

- Brief: docs/llm-orchestrator/research/YYYY-MM-DD-<slug>-brief.md (or "none")
- Source URLs the plan depends on (library docs, vendor API docs, changelogs, security advisories — each with retrieval date; these flow into `// docs:` comments in the implementer's output):
  - <URL> (retrieved 2026-05-24) — covers <API surface, pattern, advisory, changelog, or installed-version reference>
  - <URL> (retrieved 2026-05-24) — covers <...>

If outcome was COULDN'T_VERIFY: this section explicitly says "no verified sources; the implementer should not emit `// docs:` comments grounded in untrusted claims."

## Tasks

Each task has a `### N. <name>` heading with a `- [ ]` task-level checkbox
appended. Sub-step `- [ ]` checkboxes inside the body are progress notes only.
The orchestrator ticks the heading-level checkbox after the inner review loop
passes; this is the durable state across `/clear`.

### 1. <task name>  - [ ]
Independent: yes | no (depends on N)
Owner: implementer | explorer | debugger
Files:
- create: <path>
- modify: <path>:<line-range>
- test: <path>
Done when: <observable end state — e.g. "`<cmd>` prints `<line>` and all sub-steps are complete">
Stop if: <abort conditions — e.g. "2 consecutive failed fix attempts on the same test; any edit needed outside Files. Return PARTIAL or BLOCKED, don't keep trying">
Interfaces (optional; authoritative for dependency routing when present):
- introduces: <symbols/endpoints/schemas/files this task creates>
- consumes: <what this task needs that another task introduces, or "nothing">

Sub-steps (progress notes):
- [ ] write failing test in `<file>` covering `<behavior>`
- [ ] run: `<cmd>` — expect: `<line>`
- [ ] implement `<thing>` in `<file>`
- [ ] run: `<cmd>` — expect: `<line>`
- [ ] commit: `<message>`

### 2. <task name>  - [ ]
Independent: yes
Owner: implementer
Files:
- modify: <path>
Done when: <...>
Stop if: <...>

Sub-steps:
- [ ] ...

## Risks
- <risk> — <mitigation or "accept">

## Verify done
- `<command>` — `<expected output line>`
