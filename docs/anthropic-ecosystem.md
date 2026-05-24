# Leveraging the Anthropic ecosystem

LLM Orchestrator is built on top of Claude Code's native primitives. Here's what we use, why, and what's optional.

## Native primitives we use

### Slash commands (`commands/*.md`)

Each `commands/<name>.md` is a Claude Code slash command. The frontmatter `description` shows up in `/help`. The body is the prompt the harness sends when the user types `/<name>`. User input is interpolated via `$ARGUMENTS`.

### Subagents (`agents/*.md`)

`agents/orch-implementer.md`, `orch-spec-reviewer.md`, `orch-code-reviewer.md`, `orch-explorer.md`, `orch-debugger.md`, `orch-brainstormer.md` are native Claude Code subagents. Frontmatter declares:

- `name` — invoked via the Task tool with `subagent_type: <name>`
- `description` — used by Claude to decide when to dispatch
- `tools` — comma-separated allow-list
- `model` — `haiku` | `sonnet` | `opus`

Each subagent gets a fresh context window. The orchestrator passes content into the agent's prompt; the agent returns a `Status:` block.

### TodoWrite (built-in tool)

Used as the state board for plan execution. The `executing-plans` and `dispatching-subagents` skills require it. One todo per plan task. Marked `in_progress` on dispatch, `completed` after the per-task review loop.

### Skills (`skills/<name>/SKILL.md`)

Loaded on-demand via the `Skill` tool. The frontmatter `description` is the trigger; the body is the discipline. The SessionStart hook injects the `using-orchestrator` meta-skill so the protocol is always live.

### Hooks (`hooks/hooks.json`)

We use three events:
- **SessionStart** — bootstrap protocol + memory.
- **PreToolUse(Bash)** — block `--no-verify` and credential bypass.
- **Stop** — opt-in session marker + retention pruning.

### Settings (`templates/settings.json`)

A starter `.claude/settings.json` users can drop into projects. Sets `env` for hook profile, scopes `permissions` to read-mostly defaults, denies destructive patterns by default.

### CLAUDE.md hierarchy

Claude Code reads `~/.claude/CLAUDE.md` (user) and `<project>/CLAUDE.md` (project). LLM Orchestrator's `/init` writes the project-level one. The user can keep cross-project preferences in their home one — both stack.

### Plugins

`.claude-plugin/plugin.json` packages everything so users can `/plugin install llm-orchestrator` rather than copying files.

## Model selection guidance

Per Anthropic recommendations on cost-performance tradeoff:

| Task type                                  | Model     |
|--------------------------------------------|-----------|
| Classify, route, mechanical edit           | Haiku     |
| Implementation, debugging, refactoring     | Sonnet    |
| Design, architecture, multi-file rewrites  | Opus      |

Our agents come pre-configured:
- `orch-explorer`: Haiku (cheap reads)
- `orch-implementer`: Sonnet (default)
- `orch-spec-reviewer`, `orch-code-reviewer`: Sonnet
- `orch-debugger`: Sonnet
- `orch-brainstormer`: Opus (design-shaped)

Override per dispatch via the envelope's `model:` line.

## Optional: MCP servers

MCP (Model Context Protocol) servers extend Claude Code with external tools and data. LLM Orchestrator does **not** require any MCP servers — our memory is file-based by design.

Optional pairings worth considering:

| Server                | Use case                                                                 |
|-----------------------|---------------------------------------------------------------------------|
| `memory` (official)   | Cross-session memory backed by an external server (alternative to ours)  |
| `sequential-thinking` | Long chain-of-thought scratch space for `orch-debugger` or `orch-brainstormer` |
| `context7`            | Library documentation lookups during planning                            |

To add one, edit your project's `.mcp.json` (per Claude Code docs). LLM Orchestrator's memory and the MCP `memory` server can coexist — they don't conflict, but they're redundant.

## Prompt caching

Claude API supports prompt caching with a 5-minute TTL. Our SessionStart hook injects the same protocol block + memory at every session start, which gets cached on the API side after the first call. Keeping the injected context stable (don't randomize formatting) preserves cache hits across sessions.

If you maintain custom skills with high churn in their bodies, expect cache misses. The fix is discipline, not technical.

## What we ship one of (not many)

- **Output styles** — we ship exactly one (`output-styles/orchestrator.md`) that carries the Concise Agent Protocol. The protocol is the differentiator; adding alternative styles dilutes it. Users who want a different voice should fork the file rather than layer more on top.

## What we deliberately don't use

- **PostToolUse for output capture** — privacy risk and surveillance shape. Memory is what the user opts into via `/remember`; we don't log tool outputs or transcripts.
- **Background MCP observers** — same reason.

## Upstream changes

When Anthropic ships new Claude Code features, check `roadmap.md` — we add adoptions to the next minor version rather than chasing every release.
