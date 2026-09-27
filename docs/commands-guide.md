# Commands guide

Every slash command the plugin adds, grouped by when you use it. Type them in
Claude Code; on Codex, ask the assistant in plain words instead.

## Getting started

| Command | What it does |
|---|---|
| `/llm-orchestrator:onboard` | Studies an existing codebase once and, after one approval, writes its main decisions and conventions into `./CLAUDE.md`. Skips a project already onboarded. |
| `/llm-orchestrator:init` | Adds empty starter files (`CLAUDE.md`, `AGENTS.md`, `.gitignore` entries, `docs/llm-orchestrator/` folders) without overwriting. Most projects do not need it. |
| `/llm-orchestrator:cadence-init` | Turns the cadence on for the project; see [The cadence](cadence.md). `--dry-run` shows the plan first; `--adopt` keeps a rulebook the project already has. |
| `/llm-orchestrator:skills` | Lists the plugin's skills and commands and when each applies. Takes an optional keyword. |

## Planning and building

| Command | What it does |
|---|---|
| `/llm-orchestrator:research` | Checks an approach, API or version against current sources before you build on it. |
| `/llm-orchestrator:plan` | Turns an approved spec into a checklist plan under `docs/llm-orchestrator/plans/`. |
| `/llm-orchestrator:worktree` | Creates a separate working folder and branch (a git worktree) for the task. |
| `/llm-orchestrator:dispatch` | Runs the tasks in the current plan, one at a time or in parallel. |
| `/llm-orchestrator:debug` | Finds a bug's root cause before anything is fixed. |

## Checking and finishing

| Command | What it does |
|---|---|
| `/llm-orchestrator:review` | Reviews the current change and reports a verdict. `[base] [--full]`: Standard by default, Full with `--full`. Saves no file in the repository. What the verdicts mean: [Running a review by hand](codex-provider.md#what-the-verdict-means). |
| `/llm-orchestrator:verify` | Runs the project's tests, lint and typecheck, and reports the output. |
| `/llm-orchestrator:finish` | Helps you choose merge, pull request, keep or discard for the branch. Nothing destructive without confirmation. |

## Memory and long tasks

| Command | What it does |
|---|---|
| `/llm-orchestrator:remember` | Saves a fact to the right section of `CLAUDE.md` (Conventions, Decisions, People or Notes), or to plugin memory for plugin settings. |
| `/llm-orchestrator:forget` | Removes matching lines from `CLAUDE.md` or plugin memory into a trash folder, so they can be recovered. |
| `/llm-orchestrator:handoff` | Writes a short note so work can resume cleanly after the conversation is compacted. |

To add a command, see [CONTRIBUTING.md](../CONTRIBUTING.md#adding-a-command).
