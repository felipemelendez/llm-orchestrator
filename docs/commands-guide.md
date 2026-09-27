# Commands guide

Every slash command the plugin adds, and how to write a new one. Type them in
Claude Code; they do not exist on Codex.

## The commands

| Command | What it does |
|---|---|
| `/llm-orchestrator:onboard` | Studies the codebase once and, after one approval, writes its `## Decisions` and `## Conventions` into `./CLAUDE.md`. Skips a project already onboarded. Run it first on an existing project. |
| `/llm-orchestrator:init` | Adds the plugin's starter files (`CLAUDE.md`, `AGENTS.md`, `.gitignore` entries, `docs/llm-orchestrator/` folders) without overwriting. |
| `/llm-orchestrator:cadence-init` | Turns the cadence on for the project: proposes a `cadence.json` for you to confirm, then writes the rulebook, deny rules and git hooks and arms the lock. Never overwrites. `--dry-run` shows the plan; `--adopt` keeps laws the project already has. See [Enable cadence in a project](install.md#enable-cadence-in-a-project). |
| `/llm-orchestrator:plan` | Turns an approved spec into a checklist plan under `docs/llm-orchestrator/plans/`. |
| `/llm-orchestrator:worktree` | Creates a separate git worktree for the current task, marked so cleanup is safe. |
| `/llm-orchestrator:dispatch` | Runs the tasks in the current plan, one at a time or in parallel. |
| `/llm-orchestrator:review` | Reviews the current change and reports a verdict. `[base] [--full]`: Standard by default, Full with `--full`. Saves no file in the repository. |
| `/llm-orchestrator:debug` | Finds a bug's root cause before anything is fixed. |
| `/llm-orchestrator:verify` | Runs the project's tests, lint and typecheck, and reports the output. |
| `/llm-orchestrator:finish` | Helps you choose merge, pull request, keep or discard for the branch. Nothing destructive without confirmation. |
| `/llm-orchestrator:remember` | Saves a fact to the right section of `CLAUDE.md` (Conventions, Decisions, People or Notes), or to plugin memory for plugin settings. |
| `/llm-orchestrator:forget` | Removes matching lines from `CLAUDE.md` or plugin memory into a trash folder, so they can be recovered. |
| `/llm-orchestrator:research` | Checks an approach, API or version against current sources before you build on it. |
| `/llm-orchestrator:handoff` | Writes a short handoff note so work can resume cleanly after the conversation is compacted. |
| `/llm-orchestrator:skills` | Lists the plugin's skills and commands and when each applies. Takes an optional keyword. |

## Adding a command

A command is one file, `commands/<name>.md`. Its frontmatter (the block
between `---` lines at the top) needs a `description`; `argument-hint` is
optional. The body is the prompt Claude Code sends when someone types the
command, with their input in `$ARGUMENTS`.

```yaml
---
description: One line on what the command does and when to use it.
---
```

Conventions for the body:

- Say which command is running: "You are running `/llm-orchestrator:<name>`."
- Use numbered steps, and name the skills to use; the skill holds the
  discipline, the command is the entry point.
- End with a `Constraints:` section and the shape of the reply.

Example: `/llm-orchestrator:review` uses the `requesting-code-review` skill,
which runs `scripts/lib/orch-review.py` and waits for its verdict.

Add a command when people will type it often and it maps to one clear intent
("plan this", "review this"). Do not add one for a prompt people can simply
type, or for a discipline that belongs in a skill.

Name it in lowercase with hyphens, short, matching the file name. Then:

```sh
$EDITOR commands/<name>.md
./tests/validate-skills.sh
```

The validator checks each command's `description` and fails when this page's
table has no row for a command file. It does not check the body.
