# Architecture

LLM Orchestrator is folder-shaped. There is no runtime, no daemon, no compiled binary. The whole system is markdown + JSON + small shell scripts + a few plain-text files in the user's home dir for memory.

## Layers

```
┌──────────────────────────────────────────────────────────────────┐
│ Harness (Claude Code, Codex, Gemini, Copilot)                    │
│   - loads skills, commands, hooks                                │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Bootstrap: SessionStart hook                                     │
│   - injects using-orchestrator (Concise Agent Protocol)          │
│   - + latest saved session for this project                      │
│   - + project memory + global memory                             │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Skills (skills/<name>/SKILL.md)                                  │
│   - on-demand via Skill tool                                     │
│   - one file each, 2-key frontmatter                             │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Commands (commands/<name>.md)                                    │
│   - user-typed `/<name>`                                         │
│   - body is a prompt; references skills + templates              │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Templates (templates/*.md)                                       │
│   - plan, spec, review, implementer/reviewer prompts             │
│   - artifacts get committed to docs/llm-orchestrator/            │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Hooks (hooks/hooks.json → scripts/hooks/*.sh)                    │
│   - SessionStart (bootstrap), PreToolUse (guard), Stop (session) │
│   - profiles: minimal | standard | strict                        │
└──────────────────────────────────────────────────────────────────┘

User home directory (created on first use):
  ~/.llm-orchestrator/
  ├── memory/<project-hash>.md             plugin-internal: ## Research config + declined_mcp only
  ├── memory/.trash/                       soft-deleted lines from /forget
  ├── research/cache/<hash>/<lib>.md       dated doc snapshots per library
  └── research/briefs-index/<hash>.md      brief retrieval index for compounding lookups

User-curated project facts live in Claude Code's native ./CLAUDE.md (loaded by
Claude Code itself, not by this plugin's SessionStart hook).
```

## Why this shape

- **No runtime** means the kit works in any harness that can read markdown and run shell.
- **One file per skill** keeps discovery cheap. `ls skills/` is the catalog.
- **Plain-markdown memory** is grep-able, readable, editable, and trivially backed up.
- **Single hooks.json** with calls to `scripts/hooks/*.sh` keeps logic out of inline `node -e` strings.
- **Templates committed to the project** create version-controlled handoffs between phases.

## Component contract

### Skills
- File: `skills/<name>/SKILL.md`
- Frontmatter (required): `name`, `description`. Description states *triggers only*, starting with "Use when".
- Frontmatter (optional): `tools`, `profile`.
- Body: short markdown. Sections: one-line purpose, When to use, When NOT to use, Steps, Output shape, Anti-patterns.
- Linter: `tests/validate-skills.sh`.

### Commands
- File: `commands/<name>.md`
- Frontmatter: `description`.
- Body: a prompt the harness sends when the user types `/<name>`. References skills by name.

### Hooks
- File: `hooks/hooks.json` wires events → `scripts/hooks/<name>.sh`.
- Profiles via env vars:
  - `ORCH_HOOK_PROFILE=minimal` — protocol bootstrap only (meta-skill SessionStart load)
  - `ORCH_HOOK_PROFILE=standard` (default) — adds UserPromptSubmit reminders, PreToolUse guard, SubagentStop validators, and Stop-hook retention pruning
- Disable individual hooks with `ORCH_DISABLED_HOOKS="hook-a,hook-b"`.

### Templates
- File: `templates/<name>.md`
- Used by commands. Output committed to `docs/llm-orchestrator/{specs,plans,reviews}/YYYY-MM-DD-<slug>.md`.

### Memory
- User-facing facts: Claude Code's native `./CLAUDE.md` (project) and `~/.claude/CLAUDE.md` (user). `/remember` classifies on write into `## Conventions` / `## Decisions` / `## People` / `## Notes`. `/forget` soft-deletes to `~/.llm-orchestrator/memory/.trash/`. Both go through `with_lock` (`scripts/lib/orch-lock.sh`, portable across macOS/Linux).
- Plugin-internal state: `~/.llm-orchestrator/memory/<project-hash>.md` — reserved for `## Research config` (aggressiveness knob) and `declined_mcp:` entries. Read at trigger time by `orch-research-gate.sh`, not at SessionStart.
- Research cache + brief index: `~/.llm-orchestrator/research/cache/<hash>/` and `~/.llm-orchestrator/research/briefs-index/<hash>.md`. Written by the SubagentStop validator after `orch-researcher` returns; read by the gate hook on the next compelled trigger.
- `<project-hash>` = SHA-1 of (a) git remote origin URL, (b) repo root path, or (c) cwd, in that order. Resolved by `scripts/lib/orch-project.sh`.
- SessionStart loads the using-orchestrator meta-skill only. CLAUDE.md loading is Claude Code's native responsibility.
- No background observer. No surveillance hooks.

## Data flow: example feature

1. User: "Add support for X."
2. Agent invokes `brainstorming` → writes `docs/llm-orchestrator/specs/2026-05-23-X-spec.md`. User reviews.
3. Agent invokes `writing-plans` → writes `docs/llm-orchestrator/plans/2026-05-23-X-plan.md`. User reviews.
4. Agent runs `/worktree` to isolate.
5. Agent runs `/dispatch` (or parallel) per independent task → implementers return `Status:` blocks.
6. Agent runs `/review` → spec-reviewer then code-reviewer return `Issues:` blocks.
7. Agent invokes `verification-before-completion` before claiming.
8. Agent runs `/finish` → merge / PR / keep / discard.
9. Next session resumes via Claude Code's native `claude --continue` (full JSONL replay) or starts fresh; project conventions persist via CLAUDE.md, research priors via the gate hook's cache + brief-index reads.

## What lives where

- Repo root: docs a human reads first.
- `docs/`: install + guides.
- `skills/`, `commands/`, `templates/`: machine-readable artifacts.
- `hooks/`, `scripts/`: glue + runtime guardrails.
- `examples/`: walk-throughs.
- `tests/`: validators.

## Non-goals

- Not a multi-agent runtime. Agents are dispatched by the harness, not orchestrated by us.
- Not a surveillance system. PostToolUse capture is out of scope; memory is opt-in.
- Not a security framework. We expose hook profiles; the harness owns sandboxing.
