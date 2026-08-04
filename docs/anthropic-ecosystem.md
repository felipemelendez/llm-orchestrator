# Leveraging the Anthropic ecosystem

LLM Orchestrator is built on top of Claude Code's built-in features. Here's what we use, why, and what's optional. Sections under "Built-in features we use" are required; everything after "Model selection guidance" is optional.

## Built-in features we use

### Slash commands (`commands/*.md`)

Each `commands/<name>.md` is a Claude Code slash command. The frontmatter `description` shows up in `/help`. The body is the prompt Claude Code sends when the user types `/<name>`. User input is interpolated via `$ARGUMENTS`.

### Subagents (`agents/*.md`)

The files in `agents/` are native Claude Code subagents. Frontmatter declares:

- `name` — invoked via the Task tool with `subagent_type: <name>`
- `description` — used by Claude to decide when to dispatch
- `tools` — comma-separated allow-list
- `model` — `sonnet` | `opus` | `fable` | a full model ID | `inherit`
- `effort` — `low` | `medium` | `high` | `xhigh` | `max` (honored for plugin agents; `hooks`, `mcpServers`, and `permissionMode` are not)

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

**Model and effort are independent axes.** Per Anthropic's guidance ([Choosing a Claude model and effort level in Claude Code](https://claude.com/blog/claude-model-and-effort-level-in-claude-code), 2026-07-07), the model is *"the overall capability range"* — what it knows — while effort is *"how much work Claude does on your request overall including the number of files read, tools used, and how many steps it takes."*

When an agent fails, ask which one failed: **it didn't know enough → raise the model; it didn't try hard enough (skipped a file, didn't run the tests) → raise the effort.** Don't reach for the model tier to fix a thoroughness problem.

One invariant is not a preference. **A reviewer must be at least as capable as what it reviews.** Claude Code's advisor tool enforces exactly this rule for its own pairings, and the measured effect is large: an off-the-shelf weak critic moves resolve rate by 0.0/−0.2/+0.8 points, while a frontier critic moves it by +17.4 to +22.2 ([arXiv:2606.21811](https://arxiv.org/abs/2606.21811), Table 1). An **off-the-shelf** cheap reviewer is not a cheap reviewer; it is no reviewer — which is the case an agent roster actually faces. Note the paper's own thesis runs the other way: it is titled *Steer, Don't Solve: Training Small Critic Models for Large Code Agents*, and a **trained** 8B critic yields +3.0–5.2 points at 30–92× lower cost. Capability parity is what this plugin chooses given untrained critics, not what the paper concludes in general.

Our agents ship pre-configured on that basis:

| Agent | Model | Why |
|---|---|---|
| `orch-explorer` | Fable 5 | Retrieval that MISSES is indistinguishable from code that isn't there — a scout's false negative silently narrows every decision downstream of it |
| `orch-implementer` | Fable 5 | Highest-capability coding tier available |
| `orch-spec-reviewer` | Fable 5 | Reviewer tier ≥ implementer tier |
| `orch-code-reviewer` | Fable 5 | Same |
| `orch-security-reviewer` | Opus | The one deliberate exception to the Fable 5 roster: Fable 5's safety classifiers fire on benign security work, which would break exactly this seat. This leaves the security seat one tier below the Fable 5 implementer — accepted because Stage 3 is advisory and a misfiring reviewer is worse than a slightly weaker one |
| `orch-debugger` | Fable 5 | Ambiguous root-cause work |
| `orch-researcher` | Fable 5 | Its job is verifying against *live* sources, so retrieval discipline outranks cutoff freshness. Trade-off noted: Opus 5's reliable knowledge cutoff (May 2026) is fresher than Fable 5's (Jan 2026) |

Haiku 4.5 is absent by design: it accepts no `effort` parameter at all, and its reliable knowledge cutoff is Feb 2025.

**Effort is deliberately NOT pinned.** Agents inherit the session's effort level. Two pieces of evidence drove removing the earlier per-agent `effort:` pins: HAL's 21,730-rollout study found **higher reasoning effort reduced accuracy in the majority of runs**, and Anthropic's own guidance is to *"treat effort as a general preference rather than a task-by-task decision"*. The model-configuration docs additionally note that `max` "may show diminishing returns and is prone to overthinking" — `max` only, with no claim about structured output. (An earlier version of this line attributed an `xhigh`/`max`-overthinks-on-structured-output warning to the blog above; the blog contains no such warning and in fact says the opposite — that effort "generally won't artificially inflate usage for simple tasks" and that overthinking is trained against.) A pinned value also overrides the user's session preference in both directions. The plugin's own eval suite cannot measure per-agent effort effects at an affordable N, so this follows the external evidence rather than an unmeasured guess.

Effort resolution order: `CLAUDE_CODE_EFFORT_LEVEL` > frontmatter > session level > model default. Per the official docs, frontmatter effort "applies when that skill or subagent is active, overriding the session level" but not the environment variable. (This page previously listed session above frontmatter — inverted, and contradicting its own argument two paragraphs up that a pinned value overrides the user's session preference.) Setting a level a model doesn't support degrades to the highest supported level rather than erroring.

Per-invocation overrides: the Agent tool accepts `model` but **not** `effort`. Genuine per-task effort selection exists only inside Workflow scripts, via `agent(prompt, {model, effort})`.

**Turn caps.** The six read-only agents carry `maxTurns` (explorer 25, the three reviewers 30, researcher 35, debugger 40) as a runaway-repetition bound — step repetition is the largest failure mode in the MAST taxonomy (15.7%, [arXiv:2503.13657](https://arxiv.org/abs/2503.13657), N=1642). `orch-implementer` deliberately has **no** cap: its writer mutex is released by a voluntary final-turn action, and a hard cap can strand the mutex (the SubagentStop reaper mitigates this, but the primary bound for writers is the controller-side retry logic, not a turn cap).

## Optional: MCP (Model Context Protocol) servers

MCP servers extend Claude Code with external tools and data. LLM Orchestrator does **not** require any MCP servers — our memory is file-based by design.

Optional pairings worth considering:

| Server                | Use case                                                                 |
|-----------------------|---------------------------------------------------------------------------|
| `memory` (official)   | Cross-session memory backed by an external server (alternative to ours)  |
| `context7`            | Library documentation lookups during planning                            |

To add one, edit your project's `.mcp.json` (per Claude Code docs). LLM Orchestrator's memory and the MCP `memory` server can coexist — they don't conflict, but they're redundant.

## Prompt caching

Claude API supports prompt caching with a 5-minute TTL. Our SessionStart hook injects the same protocol block + memory at every session start, which gets cached on the API side after the first call. Keeping the injected context stable (don't randomize formatting) preserves cache hits across sessions.

If you maintain custom skills with high churn in their bodies, expect cache misses. The fix is discipline, not technical.

## What we ship one of (not many)

- **Output styles** — we ship exactly one (`output-styles/orchestrator.md`) that carries the Concise Agent Protocol. The protocol is the differentiator; adding alternative styles dilutes it. Users who want a different voice should fork the file rather than layer more on top.

## What we deliberately don't use

- **PostToolUse for output capture** — privacy risk and surveillance shape. We never log prompts or transcripts, and nothing is transmitted. Two local exceptions, both stated plainly rather than hidden behind "no capture": the evidence ledger (on by default under `standard`) records the first 160 characters of each verify-shaped command with its exit code and a substance verdict derived from the output; and skill telemetry (`ORCH_TELEMETRY=1`, off by default): it records skill-invocation events — skill name + timestamp + project hash — and nothing more. Memory remains what the user opts into via `/remember`.
- **Background MCP observers** — same reason.

## Native equivalents and division of labor

Claude Code now ships first-party versions of several capabilities this plugin pioneered for itself. The plugin's posture: **prefer the native mechanism when the harness provides it; the plugin's job is policy — when a step is mandatory, what counts as evidence, and in what order stages run — not mechanics.** Feature availability below was verified against a live Claude Code session on 2026-07-02; re-verify before relying on it, because the harness evolves fast.

| Capability | Native Claude Code feature | What this plugin adds | Rule |
|---|---|---|---|
| Verification | `/verify` skill (drives the affected flow end-to-end) | The gate: *when* verification is mandatory (before any done/fixed/passing claim) and the `Verify:` evidence format | Native `/verify` cannot be model-invoked (v2.1.215) and does not run tests or typechecks — it is a manual complement, not a substrate. This plugin owns the gate and the evidence format |
| Code review | `/code-review` (multi-agent, confidence-filtered; `ultra` for cloud review) and `/security-review` | Stage 1 spec-compliance review (native review doesn't check a diff against a spec), the spec-gates-quality order, and the failure-scenario evidence rule | Native review cannot be model-invoked (v2.1.215), so the plugin's reviewer agents are the only automatable substrate. `/code-review xhigh` is an excellent manual pass. Stage 1 and the gating order are this plugin's contract |
| Worktree isolation | Per-agent worktree isolation on agent dispatch | Ownership registry with atomic claims, `.orch-worktree` provenance, green-baseline capture, test-gated sequential merge-back | Prefer native isolation for the checkout itself; the registry/baseline/merge-back discipline still applies |
| Memory | CLAUDE.md hierarchy (native, automatic) plus the assistant's auto-memory directory | Write-side classification (`/remember` → Conventions/Decisions/People/Notes) and recoverable `/forget` | Native surfaces store; the plugin only classifies and soft-deletes |
| Exploration | Built-in Explore agent (read-only search) | `orch-explorer` as a tools-restricted Fable 5 variant with a `file:line` output contract | Either works; use the native Explore agent when breadth matters, `orch-explorer` when the Status-block contract matters |
| Planning | Native plan mode and Plan agent | Durable spec/plan artifacts under `docs/llm-orchestrator/` with checkbox state that survives `/clear` | Native plan mode for the proposal loop; plugin artifacts for cross-session state |
| Fan-out orchestration | `Workflow` tool (deterministic scripts, structured schema, resume) | The routing rule (`using-workflows`) and ready-made scripts (`workflows/review-diff.js`) | Already delegation-shaped: the plugin only supplies scripts and the when-to-fan-out policy |

What has **no** native equivalent and remains this plugin's own ground: the Concise Agent Protocol response shapes, the research gate (pre-spec verification of external API assumptions with four first-class outcomes), TDD and root-cause-first debugging enforcement, the brainstorm → spec → plan → dispatch pipeline with per-stage review, and the BLOCKED recovery tree.

When Anthropic ships a new Claude Code feature, adopt it deliberately rather than chasing every release: fold the native mechanism into the matching row above, shrink the plugin's own mechanics to the policy layer, and delete what the platform absorbed. A duplicated mechanism is a liability — it drifts from the native one and pays maintenance for no rigor.
