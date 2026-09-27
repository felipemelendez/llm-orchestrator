# What Claude Code does, and what this adds

The plugin is built on Claude Code's own features. Where Claude Code already
does a job, the plugin uses it; what the plugin adds is the policy around it:
when a step is required, what counts as proof, and in what order steps run.
This page lists which features it uses, how it relates to the native ones, and
how its agents' models are chosen.

## Claude Code features it uses

- **Slash commands** — `commands/<name>.md`. See the
  [commands guide](commands-guide.md).
- **Subagents** — `agents/<name>.md`, started with the `Agent` tool. Each gets
  a fresh context window. Frontmatter sets `name`, `description`, `tools`,
  `model` and optionally `effort` and `maxTurns`; for plugin agents Claude Code
  ignores `hooks`, `mcpServers` and `permissionMode`.
- **Skills** — `skills/<name>/SKILL.md`, loaded when their description matches.
  See the [skills guide](skills-guide.md).
- **Hooks** — `hooks/hooks.json` wires each event to scripts in
  `scripts/hooks/`. What each does and how to turn it off:
  [Settings](install.md#settings).
- **Settings** — `templates/settings.json` is a starter
  `.claude/settings.json` with the hook profile and a few read-mostly
  permissions.
- **CLAUDE.md** — Claude Code loads `~/.claude/CLAUDE.md` and the project's
  `CLAUDE.md` itself. The plugin only writes to them
  (`/llm-orchestrator:init`, `/llm-orchestrator:onboard`,
  `/llm-orchestrator:remember`).
- **Output style** — one, `output-styles/orchestrator.md`, which carries the
  Concise Agent Protocol's reply shapes and keeps Claude Code's own coding
  instructions (`keep-coding-instructions: true`).
- **Plugins** — `.claude-plugin/plugin.json` packages it all for
  `/plugin install llm-orchestrator@llm-orchestrator`.

## Native features and the plugin's part

Checked against the Claude Code documentation and Claude Code 2.1.282 on
2026-09-25. Claude Code changes often; check again before relying on a row.

| Job | Claude Code has | The plugin adds | How they split |
|---|---|---|---|
| Verification | `/verify` (runs the app's flow; you start it by hand since 2.1.215; it does not run tests) | The rule that no done, fixed or passing claim goes out without the command and its output, and the end-of-turn check on `Verification: PASS` | `/verify` is a manual extra. The plugin owns the rule and the evidence format |
| Code review | `/code-review`, `/security-review` | `scripts/lib/orch-review.py`: runs `/code-review` and `codex review` against the spec, adds a second provider on Full, a failing command for every finding, fixes tested in a sandbox, and a verdict | The agent can run `/code-review` itself since 2.1.246, unless you set `skillOverrides: {"code-review": "user-invocable-only"}`. The plugin's review is `orch-review.py` |
| Worktrees | Per-agent worktrees (`isolation: worktree`). This native feature starts each worktree from the remote default branch, not your current `HEAD`, unless you set `worktree.baseRef: "head"` (a plugin cannot), and never carries uncommitted changes | The plugin cuts its own worktrees from your current `HEAD`, records which agent owns each, captures a test baseline, and merges parallel branches back through a merge queue (the branches are combined and tested once, and your branch moves only to a combination that passed) | The plugin uses its own worktrees for agents that write code |
| Memory | `CLAUDE.md`, auto-memory, per-agent `memory:` | Sorting facts into sections on write, and recoverable deletes | Claude Code stores and loads; the plugin classifies. Its agents do not set `memory:`, which would give read-only agents write tools |
| Exploration | Built-in Explore agent | `orch-explorer`: read-only, returns `file:line` references | Either works; use `orch-explorer` when you want its reply shape |
| Planning | Plan mode and the Plan agent | Spec and plan files under `docs/llm-orchestrator/` whose checkboxes survive `/clear` | Plan mode for the proposal; the plugin's files for state across sessions |
| Scripted fan-out | `Workflow` tool | Nothing | A Workflow script cannot run commands or read files, and runs only on Claude Code, so the review is a Python script instead |

With no native counterpart: the reply shapes of the
[Concise Agent Protocol](../concise-agent-protocol.md), the research step
before a spec, test-first and root-cause-first discipline, the brainstorm →
spec → plan → build pipeline, and the recovery steps for a blocked agent.

When Claude Code ships a feature that does one of these jobs, the plugin
should adopt it and remove its own version.

## Agents and models

| Agent | Model | Job |
|---|---|---|
| `orch-explorer` | Sonnet | Read-only search that runs often |
| `orch-implementer` | Opus | Writes the code for one task |
| `orch-spec-reviewer` | Opus, effort `high` | Reviews specs during brainstorming |
| `orch-debugger` | Opus | Finds a bug's root cause |
| `orch-researcher` | Opus | Checks plans against live sources |

`opus` means the current Opus model and `sonnet` the latest Sonnet
([model configuration](https://code.claude.com/docs/en/model-config)). The
files in `agents/` are the source of truth. Why these choices, and how effort
is set: [ARCHITECTURE.md, Models and effort](../ARCHITECTURE.md#models-and-effort).

## Optional: MCP servers

The plugin needs no MCP servers; its memory is plain files. Useful additions:
`context7` for library docs during planning and research, or the official
`memory` server (it works alongside the plugin's memory, but duplicates it).
Add them in your project's `.mcp.json`.

## Privacy

No prompts, commands or outputs are recorded or sent anywhere. The completion
check reads the transcript Claude Code already keeps and writes nothing. The
one exception is opt-in: with `ORCH_TELEMETRY=1`, each skill use is recorded
locally as skill name, time and project hash.
