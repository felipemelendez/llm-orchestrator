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
- `model` — `haiku` | `sonnet` | `opus` | `fable` | a full model ID | `inherit`
- `effort` — `low` | `medium` | `high` | `xhigh` | `max` (honored for plugin agents; `hooks`, `mcpServers`, and `permissionMode` are not)

Each subagent gets a fresh context window. The orchestrator passes content into the agent's prompt; the agent returns a `Status:` block.

### Task tools (built-in)

Used as the state board for plan execution. The `executing-plans` and `dispatching-subagents` skills require them. `TaskCreate` makes one task per plan task; `TaskUpdate` marks it `in_progress` on dispatch and `completed` after the per-task review loop; `TaskList` reports current state.

### Skills (`skills/<name>/SKILL.md`)

Loaded on-demand via the `Skill` tool. The frontmatter `description` is the trigger; the body is the discipline. The SessionStart hook injects the `using-orchestrator` core, which says when a skill applies; the reply-format rule is added only in a cadence-enabled project.

### Hooks (`hooks/hooks.json`)

We wire sixteen hook scripts across seven events; `hooks/hooks.json` is the source of truth:
- **SessionStart** — bootstrap the `using-orchestrator` core, plus the reply format in a cadence-enabled project. Loading CLAUDE.md stays Claude Code's own job.
- **UserPromptSubmit** — per-turn protocol reminder (cadence-enabled projects only), research gate, handoff nudge.
- **PreToolUse** — the safety guards: destructive git, verification bypass, the cadence unlock guard.
- **PostToolUse / PostToolUseFailure** — evidence ledger, and opt-in skill telemetry.
- **SubagentStop** — Status-block validator, researcher validator, retry cap, writer-mutex reaper.
- **Stop** — protocol grader, verify gate, retry cap, retention pruning.

### Settings (`templates/settings.json`)

A starter `.claude/settings.json` users can drop into projects. Sets `env` for hook profile, scopes `permissions` to read-mostly defaults, denies destructive patterns by default.

### CLAUDE.md hierarchy

Claude Code reads `~/.claude/CLAUDE.md` (user) and `<project>/CLAUDE.md` (project). LLM Orchestrator's `/init` writes the project-level one. The user can keep cross-project preferences in their home one — both stack.

### Plugins

`.claude-plugin/plugin.json` packages everything so users can `/plugin install llm-orchestrator` rather than copying files.

## Model selection guidance

**Model and effort are independent axes.** Per Anthropic's guidance ([Choosing a Claude model and effort level in Claude Code](https://claude.com/blog/claude-model-and-effort-level-in-claude-code), 2026-07-07), the model is *"the overall capability range"* — what it knows — while effort is *"how much work Claude does on your request overall including the number of files read, tools used, and how many steps it takes."*

When an agent fails, ask which one failed: **it didn't know enough → raise the model; it didn't try hard enough (skipped a file, didn't run the tests) → raise the effort.** Don't reach for the model tier to fix a thoroughness problem.

One invariant is not a preference. **A reviewer must be at least as capable as what it reviews.** Claude Code's advisor tool enforces exactly this rule for its own pairings, and the measured effect is large. In the September 2026 revision of [arXiv:2606.21811](https://arxiv.org/abs/2606.21811) (v2, Table 1, SWE-Bench Verified), an untrained 4B or 8B critic moves resolve rate by +0.2 to +1.4 points on three of the six agents, and by −3.6, +3.8 and +8.2 on the other three, while a Claude Opus 4.6 critic moves it by +18.0 and +18.2 on the two agents it was run with. An **untrained** cheap reviewer adds little and sometimes hurts, which is the case an agent roster actually faces. Note the paper's own thesis runs the other way: it is titled *Steer, Don't Solve: Training Small Critic Models for Large Code Agents*, and **trained** 4B and 8B critics add +2.6 to +16.0 points; on the two Qwen agents the 8B SFT critic gives a 5.2–6.0× lower total cost than the Opus critic (Fig. 4, Sec. 3.4). Capability parity is what this plugin chooses given untrained critics, not what the paper concludes in general.

Our agents ship pre-configured on that basis. Every agent except `orch-explorer` sets `model: opus`, which is Opus 5.5 on the Anthropic API ([model configuration](https://code.claude.com/docs/en/model-config)); the explorer sets `model: sonnet`, the latest Sonnet. Felipe set the Opus policy on 2026-09-21 after the Fable review route was rate-limited, and the Sonnet explorer on 2026-09-25. Opus 5.5 also costs less per token than Fable ([models overview](https://platform.claude.com/docs/en/about-claude/models/overview)). The policy list in `tests/validate-skills.sh` checks every pin.

| Agent | Model | Why |
|---|---|---|
| `orch-explorer` | Sonnet | Read-only search that runs often; Sonnet costs half as much as Opus. The risk, not yet measured, is that a missed result narrows every later decision |
| `orch-implementer` | Opus | The roster's coding tier |
| `orch-spec-reviewer` | Opus | Reviewer tier ≥ implementer tier |
| `orch-code-reviewer` | Opus | Same |
| `orch-security-reviewer` | Opus | Same. Opus 5.5 runs the same safety classifiers as Fable: on either model, a request flagged as cybersecurity re-runs on Opus 4.8 and the session stays there ([automatic model fallback](https://code.claude.com/docs/en/model-config#automatic-model-fallback)). Opus therefore does not avoid those fallbacks on security work |
| `orch-debugger` | Opus | Ambiguous root-cause work |
| `orch-researcher` | Opus | Its job is verifying against *live* sources, so retrieval discipline outranks cutoff freshness. Opus 5.5 and Fable share a reliable knowledge cutoff of June 2026 |

Haiku 4.5 is absent by design: it accepts no `effort` parameter at all, and its reliable knowledge cutoff is Feb 2025.

**Effort is set only on the reviewers.** `orch-spec-reviewer`, `orch-code-reviewer` and `orch-security-reviewer` set `effort: high`; every other agent inherits the session's level. Opus 5.5 defaults to `medium` while every other effort-capable model defaults to `high` ([model configuration](https://code.claude.com/docs/en/model-config#adjust-effort-level)), so without a pin the reviewers would run at `medium` in a session where nobody has chosen a level. The reason for the exception: a reviewer that stops early misses findings, and the model-choice guidance above says to raise effort when an agent did not try hard enough. The evidence against pinning still applies to the other agents: HAL's 21,730-rollout study found that in 21 of 36 settings more reasoning effort gave equal or lower accuracy ([arXiv:2510.11977](https://arxiv.org/abs/2510.11977)), and Anthropic advises treating effort as a general preference. A pin overrides the person's session choice in both directions, so a session at `max` runs its reviewers at `high`. Whether `high` improves review is not measured; the evaluation work is meant to test it.

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

Claude API supports prompt caching with a 5-minute TTL. Our SessionStart hook injects the same protocol block at every session start, which gets cached on the API side after the first call. Keeping the injected context stable (don't randomize formatting) preserves cache hits across sessions.

If you maintain custom skills with high churn in their bodies, expect cache misses. The fix is discipline, not technical.

## What we ship one of (not many)

- **Output styles** — we ship exactly one (`output-styles/orchestrator.md`) that carries the Concise Agent Protocol. It sets `keep-coding-instructions: true`, so choosing it keeps Claude Code's own instructions on scoping and verifying work. Claude Code's built-in Concise style covers "no preamble, no recap" but not the six headers. Users who want a different voice should fork the file rather than layer more on top.

## What we deliberately don't use

- **PostToolUse for output capture** — privacy risk and surveillance shape. We never log prompts or transcripts, and nothing is transmitted. Two local exceptions, both stated plainly rather than hidden behind "no capture": the evidence ledger (on by default under `standard`) records the first 400 characters of each verify-shaped command with its exit code and a substance verdict derived from the output; and skill telemetry (`ORCH_TELEMETRY=1`, off by default): it records skill-invocation events — skill name + timestamp + project hash — and nothing more. Memory remains what the user opts into via `/remember`.
- **Background MCP observers** — same reason.

## Native equivalents and division of labor

Claude Code now ships first-party versions of several capabilities this plugin pioneered for itself. The plugin's posture: **prefer the native mechanism when the harness provides it; the plugin's job is policy — when a step is mandatory, what counts as evidence, and in what order stages run — not mechanics.** Feature availability below was checked on 2026-09-25 against the Claude Code docs and Claude Code v2.1.282 in a scratch repository; check again before relying on it, because the harness changes often.

| Capability | Native Claude Code feature | What this plugin adds | Rule |
|---|---|---|---|
| Verification | `/verify` skill (drives the affected flow end-to-end) | The gate: *when* verification is mandatory (before any done/fixed/passing claim) and the `Verify:` evidence format | Native `/verify` cannot be model-invoked (v2.1.215) and does not run tests or typechecks — it is a manual complement, not a substrate. This plugin owns the gate and the evidence format |
| Code review | `/code-review` (runs as a background subagent; the effort level trades coverage for confidence; `ultra` for cloud review) and `/security-review` | Stage 1 spec-compliance review (native review doesn't check a diff against a spec), the spec-gates-quality order, and the failure-scenario evidence rule | Claude can start `/code-review` on its own; since v2.1.246 that no longer depends on a feature flag fetched from Anthropic (a person can turn that off with `skillOverrides: {"code-review": "user-invocable-only"}`); in a 2026-09-25 scratch run, a plain "review the changes on this branch" made the model call it. The plugin's review flow does not call it; whether it becomes one of the reviewers is the review design's decision. Stage 1 and the gating order are this plugin's contract |
| Worktree isolation | Per-agent worktree isolation on agent dispatch (`isolation: worktree`) | Worktrees cut from the current `HEAD`, ownership registry with atomic claims, `.orch-worktree` provenance, green-baseline capture, test-gated sequential merge-back | Do not use native isolation for writers. It branches from the remote default branch, not the current `HEAD`, unless the person sets `worktree.baseRef: "head"`; a plugin's `settings.json` cannot set it (only `agent` and `subagentStatusLine` take effect), and even `"head"` carries no uncommitted changes. All three were confirmed in a scratch repository on 2026-09-25 |
| Memory | CLAUDE.md hierarchy (native, automatic) plus the assistant's auto-memory directory, and per-agent `memory:` | Write-side classification (`/remember` → Conventions/Decisions/People/Notes) and recoverable `/forget` | Native surfaces store; the plugin only classifies and soft-deletes. The plugin's agents do not set `memory:`: it does nothing when auto memory is off, and it gives the agent Read, Write and Edit, which the read-only agents must not have |
| Exploration | Built-in Explore agent (read-only search) | `orch-explorer` as a tools-restricted Sonnet variant with a `file:line` output contract | Either works; use the native Explore agent when breadth matters, `orch-explorer` when the Status-block contract matters |
| Planning | Native plan mode and Plan agent | Durable spec/plan artifacts under `docs/llm-orchestrator/` with checkbox state that survives `/clear` | Native plan mode for the proposal loop; plugin artifacts for cross-session state |
| Fan-out orchestration | `Workflow` tool (deterministic scripts, structured schema, resume) | The routing rule (`using-workflows`) and ready-made scripts (`workflows/review-diff.js`) | Already delegation-shaped: the plugin only supplies scripts and the when-to-fan-out policy |

What has **no** native equivalent and remains this plugin's own ground: the Concise Agent Protocol response shapes, the research gate (pre-spec verification of external API assumptions with four first-class outcomes), TDD and root-cause-first debugging enforcement, the brainstorm → spec → plan → dispatch pipeline with per-stage review, and the BLOCKED recovery tree.

When Anthropic ships a new Claude Code feature, adopt it deliberately rather than chasing every release: fold the native mechanism into the matching row above, shrink the plugin's own mechanics to the policy layer, and delete what the platform absorbed. A duplicated mechanism is a liability — it drifts from the native one and pays maintenance for no rigor.
