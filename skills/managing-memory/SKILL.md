---
name: managing-memory
description: Use when the user says "remember", "save this", "I told you before", or "forget that". Classifies notes into Claude Code's native CLAUDE.md and research-gate state.
---

# Memory

A thin layer over Claude Code's native CLAUDE.md — persistence itself is native, and the native
paths (`claude --continue`, `/resume`) are strictly better than reimplementing them. What this
skill adds: auto-classification on `/llm-orchestrator:remember`, soft-delete on
`/llm-orchestrator:forget`, and plugin-internal memory for research-gate state.

Two native surfaces, two owners: **CLAUDE.md** is the *user's* curated memory — that's what this
skill writes to. The harness may also keep an *assistant-owned* auto-memory directory; this skill
never writes there, and facts the user asks to remember belong in CLAUDE.md, not in assistant
notes.

## Where things live

| Target file                                     | What goes there                                            | Loaded by                              |
|-------------------------------------------------|-------------------------------------------------------------|----------------------------------------|
| `./CLAUDE.md` (project)                          | Per-project facts: conventions, decisions, people, notes   | Claude Code (native, automatic)        |
| `~/.claude/CLAUDE.md` (user)                     | Cross-project facts ("I prefer pnpm everywhere")           | Claude Code (native, automatic)        |
| `~/.llm-orchestrator/memory/<hash>.md` (plugin)  | `## Research config`, `declined_mcp:` entries              | `orch-research-gate.sh` at trigger time |
| `~/.llm-orchestrator/research/cache/<hash>/`     | Dated doc snapshots per library (research-gate cache)      | `orch-research-gate.sh` at trigger time |
| `~/.llm-orchestrator/research/briefs-index/`     | `<library>|<outcome>|<date>|<brief-path>` per project       | `orch-research-gate.sh` at trigger time |

`<project-hash>` is 12 hex chars of SHA-1 over (in order) git remote URL → repo root → `pwd`.
Computed by `scripts/lib/orch-project.sh`.

## How `/llm-orchestrator:remember` routes

Three branches in priority order:

1. **Plugin-config branch.** Fact starts with `research_aggressiveness:` or matches
   `declined_mcp:` → `~/.llm-orchestrator/memory/<hash>.md` under `## Research config`.
2. **Global branch.** Fact is cross-project (model judgment, or user explicitly says global) →
   `~/.claude/CLAUDE.md`.
3. **Project branch (default).** `./CLAUDE.md` (or `./.claude/CLAUDE.md` if that's where the
   project keeps it), under the section the fact fits: tooling preferences → `## Conventions`,
   choices made ("decided", "X over Y") → `## Decisions`, ownership → `## People`, everything
   else → `## Notes`.

Writes go through `append_under_section` from `scripts/lib/orch-lock.sh`, which creates the
section if missing and serializes concurrent sessions under `with_lock` (`flock` where available,
`mkdir`-based fallback on macOS/POSIX).

## Verify on load

A stored fact can drift — "use Mocha" recorded 8 months ago may predate the repo's move to
Vitest. Before acting on a loaded fact, spot-check it against reality: tooling conventions
against the manifest (`package.json`, `pyproject.toml`, …), people against recent `git log`
authors; trust decisions unless the codebase obviously contradicts. If a fact is stale,
`/llm-orchestrator:forget` it (with confirmation) and remember the corrected version.

## What belongs in memory

Conventions, decisions, ownership, and hard-earned facts ("the test DB user is `dev_ro`, not
`dev`"). Not: anything secret — `/llm-orchestrator:remember` refuses credential-shaped strings —
raw tool output, things derivable from the repo, or narrative. Plugin memory is reserved for
research-gate state only; user-facing facts go in CLAUDE.md, and project-specific facts go in
`./CLAUDE.md`, not the user file.

## Soft-delete

`/llm-orchestrator:forget` writes removed lines to `~/.llm-orchestrator/memory/.trash/<slug>-<ts>.md`
before removing them from the source — whichever file that is. Show the user what's about to be
removed before removing it. Recovery: `ls -1t ~/.llm-orchestrator/memory/.trash/`, inspect, and
append the content back to the source file.

Retention: the Stop hook prunes trash older than `ORCH_SESSION_RETENTION_DAYS` (default 90).
CLAUDE.md files are never auto-pruned. The research cache is pruned separately at
`ORCH_RESEARCH_RETENTION_DAYS` (default 30), honoring per-file `cache_ttl_days:` frontmatter.

## Research config (plugin memory only)

The research-gate reads `## Research config` from `~/.llm-orchestrator/memory/<project-hash>.md`:

```markdown
## Research config
- research_aggressiveness: standard           # high | standard | low (default: standard)
- declined_mcp: context7 for library-docs (2026-05-24)
- declined_mcp: stripe-mcp for stripe-api (2026-05-24)
```

Each `declined_mcp` entry is one line: MCP name, the signal it was suggested for, and the date.
The classifier skips any (MCP, signal) pair declined within the last 12 months.

- `high` — triggers research on any library mention or architectural verb.
- `standard` (default) — triggers on library + (version OR security OR architectural verb).
- `low` — triggers only on version pins, security keywords, or explicit `/llm-orchestrator:research`.

Set via `/llm-orchestrator:remember research_aggressiveness: high`. The gate hook reads on every
trigger — no restart needed.
