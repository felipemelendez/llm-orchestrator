---
name: managing-memory
description: Use when the user says "remember", "save this", "I told you before", or "forget that". Classifies notes into Claude Code's native CLAUDE.md and research-gate state.
---

# Memory

A thin layer over Claude Code's native CLAUDE.md. We don't reinvent persistence — Claude Code already loads `CLAUDE.md` (project / user / local / managed) automatically at session start. What this skill adds:

1. **Auto-classification on `/llm-orchestrator:remember`** — facts route into `## Conventions`, `## Decisions`, `## People`, or `## Notes` sections of the right CLAUDE.md.
2. **Soft-delete via `/llm-orchestrator:forget`** — removed lines move to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable.
3. **Plugin-internal memory** at `~/.llm-orchestrator/memory/<project-hash>.md` for research-gate state that doesn't belong in user-facing CLAUDE.md — `## Research config` (aggressiveness knob) and `declined_mcp:` entries.

Two native surfaces, two owners: **CLAUDE.md** is the *user's* curated memory — that's what this skill writes to. The harness may also keep an *assistant-owned* auto-memory directory (Claude Code persists the model's own notes across sessions); this skill never writes there, and facts the user asks to remember belong in CLAUDE.md, not in assistant notes.

## Where things live

| Target file                                     | What goes there                                            | Loaded by                              |
|-------------------------------------------------|-------------------------------------------------------------|----------------------------------------|
| `./CLAUDE.md` (project)                          | Per-project facts: conventions, decisions, people, notes   | Claude Code (native, automatic)        |
| `~/.claude/CLAUDE.md` (user)                     | Cross-project facts ("I prefer pnpm everywhere")           | Claude Code (native, automatic)        |
| `~/.llm-orchestrator/memory/<hash>.md` (plugin)  | `## Research config`, `declined_mcp:` entries              | `orch-research-gate.sh` at trigger time |
| `~/.llm-orchestrator/research/cache/<hash>/`     | Dated doc snapshots per library (research-gate cache)      | `orch-research-gate.sh` at trigger time |
| `~/.llm-orchestrator/research/briefs-index/`     | `<library>|<outcome>|<date>|<brief-path>` per project       | `orch-research-gate.sh` at trigger time |

`<project-hash>` is 12 hex chars of SHA-1 over (in order) git remote URL → repo root → `pwd`. Computed by `scripts/lib/orch-project.sh`.

## How `/llm-orchestrator:remember` routes

Three branches in priority order:

1. **Plugin-config branch.** Fact starts with `research_aggressiveness:` or matches `declined_mcp:` → writes to `~/.llm-orchestrator/memory/<hash>.md` under `## Research config`. The gate hook reads this at trigger time.
2. **Global branch.** Fact is cross-project (model judgment, or user explicitly invokes global) → writes to `~/.claude/CLAUDE.md`. Loaded by Claude Code natively at session start.
3. **Project branch (default).** Writes to `./CLAUDE.md` (or `./.claude/CLAUDE.md` if that's where the project keeps it). Section assigned by the auto-classifier:

   | Pattern matches                                          | Section      |
   |----------------------------------------------------------|--------------|
   | "use X", "prefer X", "X not Y", tool names (pnpm/eslint…) | Conventions  |
   | "decided", "chose", "picked", "X over Y"                  | Decisions    |
   | "owns", "lead", "responsible", team / Slack mentions      | People       |
   | (default)                                                 | Notes        |

`append_under_section` from `scripts/lib/orch-lock.sh` creates the section if it doesn't exist, then appends underneath. All writes go through `with_lock` so concurrent sessions serialize without corruption.

## Verify on load

CLAUDE.md is loaded by Claude Code automatically; the SessionStart hook does not. But the facts can still drift — a fact stored 8 months ago ("use Mocha") may no longer reflect reality (the repo now uses Vitest). Before acting on a loaded fact, spot-check it:

- Conventions about tooling: check `package.json`, `pyproject.toml`, `Cargo.toml`, `Gemfile`, `go.mod`.
- People: check `git log --since="3 months" --format='%an' | sort -u` to see who's still active.
- Decisions: trust unless the codebase obviously contradicts.

If a fact is stale, `/llm-orchestrator:forget` it (with confirmation) and `/llm-orchestrator:remember` the corrected version.

## What goes in memory

- Conventions: "this repo uses pnpm, not npm"
- Decisions: "we picked tRPC over GraphQL in May 2026"
- Hard-earned facts: "the test DB user is `dev_ro`, not `dev`"
- People: "Sara owns the auth subsystem"
- Research-gate knobs (plugin memory only): `research_aggressiveness: high`, `declined_mcp: stripe-mcp for stripe-api (2026-05-24)`

What does NOT:
- Raw tool inputs/outputs (privacy).
- Anything secret (passwords, tokens, PII) — `/llm-orchestrator:remember` refuses credential-shaped strings.
- Things derivable from the repo (file lists, function signatures).
- Verbose narrative ("we spent an hour debugging…").

## Concurrent safety

`/llm-orchestrator:remember` and `/llm-orchestrator:forget` write under the portable lock helper at `scripts/lib/orch-lock.sh`. It uses `flock` where available (Linux), or `mkdir`-based locking as a portable fallback (macOS, any POSIX). Two parallel sessions writing the same file serialize without corruption.

## Soft-delete

`/llm-orchestrator:forget` writes the removed lines to `~/.llm-orchestrator/memory/.trash/<slug>-<ts>.md` before removing them from the source — regardless of whether the source is project CLAUDE.md, user CLAUDE.md, or plugin memory. Recovery:

```bash
ls -1t ~/.llm-orchestrator/memory/.trash/
# Inspect the trash file, then append matching content back to the source file.
```

## Trash and cache retention

The Stop hook prunes `~/.llm-orchestrator/memory/.trash/*.md` older than `ORCH_SESSION_RETENTION_DAYS` (default 90) every turn. CLAUDE.md files are never auto-pruned — they accumulate until you `/llm-orchestrator:forget`.

The research cache is pruned separately at `ORCH_RESEARCH_RETENTION_DAYS` (default 30); per-file TTL overrides are honored via `cache_ttl_days:` frontmatter.

## Research config (plugin memory only)

The research-gate reads a `## Research config` section from `~/.llm-orchestrator/memory/<project-hash>.md` if present:

```markdown
## Research config
- research_aggressiveness: standard           # high | standard | low (default: standard)
- declined_mcp: context7 for library-docs (2026-05-24)
- declined_mcp: stripe-mcp for stripe-api (2026-05-24)
```

Each `declined_mcp` entry is one line: the MCP name, the signal it was suggested for, and the date. The classifier reads these before nudging and skips any (MCP, signal) pair declined within the last 12 months.

- `research_aggressiveness: high` — triggers research on any library mention or architectural verb.
- `research_aggressiveness: standard` (default) — triggers on library + (version OR security OR architectural verb).
- `research_aggressiveness: low` — triggers only on version pins, security keywords, or explicit `/llm-orchestrator:research`.

Set via `/llm-orchestrator:remember research_aggressiveness: high`. The gate hook reads on every trigger — no restart needed.

## Commands

- `/llm-orchestrator:remember <fact>` — append to the right CLAUDE.md (or plugin memory for research config) under the inferred section
- `/llm-orchestrator:forget <pattern>` — soft-delete matching lines from wherever they live

## Cross-session continuity

Memory persistence is Claude Code's native responsibility. For resuming where a prior session left off, use `claude --continue` (replays the full JSONL conversation) or `/resume` to pick from history. For mid-session lookups across memory, `grep ./CLAUDE.md ~/.claude/CLAUDE.md`. The plugin doesn't reimplement these — the native paths are strictly better.

## Anti-patterns

- Writing 5-line essays as "facts".
- Putting secrets in memory files.
- Forgetting on user instruction without showing what's about to be removed.
- Editing user CLAUDE.md with project-specific stuff (use `./CLAUDE.md`).
- Putting user-facing facts in plugin memory (use CLAUDE.md). Plugin memory is reserved for research-gate state only.
