# Leveraging the Anthropic ecosystem

LLM Orchestrator is built on top of Claude Code's built-in features. Here's what we use, why, and what's optional. Sections under "Built-in features we use" are required; everything after "Model selection guidance" is optional.

## Built-in features we use

### Slash commands (`commands/*.md`)

Each `commands/<name>.md` is a Claude Code slash command. The frontmatter `description` shows up in `/help`. The body is the prompt Claude Code sends when the user types `/<name>`. User input is interpolated via `$ARGUMENTS`.

### Subagents (`agents/*.md`)

`agents/orch-implementer.md`, `orch-spec-reviewer.md`, `orch-code-reviewer.md`, `orch-security-reviewer.md`, `orch-explorer.md`, `orch-debugger.md`, `orch-brainstormer.md`, `orch-researcher.md` are native Claude Code subagents. Frontmatter declares:

- `name` — invoked via the Task tool with `subagent_type: <name>`
- `description` — used by Claude to decide when to dispatch
- `tools` — comma-separated allow-list
- `model` — `haiku` | `sonnet` | `opus`

Each subagent gets a fresh context window. The orchestrator passes content into the agent's prompt; the agent returns a `Status:` block.

### Task tools (built-in)

Used as the state board for plan execution. The `executing-plans` and `dispatching-subagents` skills require them. `TaskCreate` makes one task per plan task; `TaskUpdate` marks it `in_progress` on dispatch and `completed` after the per-task review loop; `TaskList` reports current state.

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
- `orch-spec-reviewer`, `orch-code-reviewer`, `orch-security-reviewer`: Sonnet
- `orch-debugger`, `orch-researcher`: Sonnet
- `orch-brainstormer`: Opus (design-shaped)

Override per dispatch via the envelope's `model:` line.

## Optional: MCP (Model Context Protocol) servers

MCP servers extend Claude Code with external tools and data. LLM Orchestrator does **not** require any MCP servers — our memory is file-based by design.

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

- **PostToolUse for output capture** — privacy risk and surveillance shape. We never log tool outputs, arguments, prompts, or transcripts. The one opt-in, event-only exception is skill telemetry (`ORCH_TELEMETRY=1`, off by default): it records skill-invocation events — skill name + timestamp + project hash — and nothing more. Memory remains what the user opts into via `/remember`.
- **Background MCP observers** — same reason.

## Native equivalents and division of labor

Claude Code now ships first-party versions of several capabilities this plugin pioneered for itself. The plugin's posture: **prefer the native mechanism when the harness provides it; the plugin's job is policy — when a step is mandatory, what counts as evidence, and in what order stages run — not mechanics.** Feature availability below was verified against a live Claude Code session on 2026-07-02; re-verify before relying on it, because the harness evolves fast.

| Capability | Native Claude Code feature | What this plugin adds | Rule |
|---|---|---|---|
| Verification | `/verify` skill (drives the affected flow end-to-end) | The gate: *when* verification is mandatory (before any done/fixed/passing claim) and the `Verify:` evidence format | Prefer native `/verify` for mechanics; this plugin decides when it must run |
| Code review | `/code-review` (multi-agent, confidence-filtered; `ultra` for cloud review) and `/security-review` | Stage 1 spec-compliance review (native review doesn't check a diff against a spec), the spec-gates-quality order, and the failure-scenario evidence rule | Native review is an accepted substrate for Stage 2/3 mechanics; Stage 1 and the gating order are this plugin's contract |
| Worktree isolation | Per-agent worktree isolation on agent dispatch | Ownership registry with atomic claims, `.orch-worktree` provenance, green-baseline capture, test-gated sequential merge-back | Prefer native isolation for the checkout itself; the registry/baseline/merge-back discipline still applies |
| Memory | CLAUDE.md hierarchy (native, automatic) plus the assistant's auto-memory directory | Write-side classification (`/remember` → Conventions/Decisions/People/Notes) and recoverable `/forget` | Native surfaces store; the plugin only classifies and soft-deletes |
| Exploration | Built-in Explore agent (read-only search) | `orch-explorer` as a tools-restricted Haiku variant with `file:line` output contract | Either works; use the native Explore agent when breadth matters, `orch-explorer` when the Status-block contract matters |
| Planning | Native plan mode and Plan agent | Durable spec/plan artifacts under `docs/llm-orchestrator/` with checkbox state that survives `/clear` | Native plan mode for the proposal loop; plugin artifacts for cross-session state |
| Fan-out orchestration | `Workflow` tool (deterministic scripts, structured schema, resume) | The routing rule (`using-workflows`) and ready-made scripts (`workflows/review-diff.js`) | Already delegation-shaped: the plugin only supplies scripts and the when-to-fan-out policy |

What has **no** native equivalent and remains this plugin's own ground: the Concise Agent Protocol response shapes, the research gate (pre-spec verification of external API assumptions with four first-class outcomes), TDD and root-cause-first debugging enforcement, the brainstorm → spec → plan → dispatch pipeline with per-stage review, and the BLOCKED recovery tree.

When Anthropic ships a new Claude Code feature, adopt it deliberately rather than chasing every release: fold the native mechanism into the matching row above, shrink the plugin's own mechanics to the policy layer, and delete what the platform absorbed. A duplicated mechanism is a liability — it drifts from the native one and pays maintenance for no rigor.
