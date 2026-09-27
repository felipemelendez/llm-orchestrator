# Install and settings

How to install the plugin on Claude Code, check it, update it, and change its
settings. For Codex, see [Codex](codex.md). To turn on the cadence in a
project, see [The cadence](cadence.md).

## Requirements

Claude Code, Bash, Git and Python 3. The visual brainstorming panel also needs
Node.js.

## Install on Claude Code

Run these one at a time inside Claude Code:

```text
/plugin marketplace add felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code.

## Check your install

Run `/plugin`: it is installed when `llm-orchestrator` is listed. Typing
`/llm-orchestrator:` should also show the plugin's commands.

For a clone of the repository (the install methods below), you can also run:

```sh
./scripts/install.sh --check
```

It prints `LLM Orchestrator check: OK` when the clone is complete, and lists
which parts are set up on this machine.

## Update

A new release does not reach you on its own. In your terminal:

```sh
claude plugin marketplace update llm-orchestrator
claude plugin update llm-orchestrator@llm-orchestrator
```

Restart Claude Code. For a `--link` or `--copy` install, rerun that installer
from an updated clone. For Codex, see [Codex: Update](codex.md#update).
Upgrading from 0.11 or older: follow the upgrade notes in the
[CHANGELOG](../CHANGELOG.md).

## Other ways to install

Each of these starts from a clone:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
```

- **Try it without installing** (for development): `claude --plugin-dir "$(pwd)"`.
  Claude Code reads plugin files at startup, so restart after editing;
  `/clear` is not enough.
- **Symlink:** `./scripts/install.sh --link` creates `~/.claude/llm-orchestrator`,
  pointing at your clone. Then run `/plugin marketplace add ~/.claude/llm-orchestrator`
  and `/plugin install llm-orchestrator@llm-orchestrator` in Claude Code.
  `git pull` in the clone updates the plugin.
- **Copy into one project:** `./scripts/install.sh --copy ~/myproject` copies
  the plugin into `~/myproject/.claude/`, with a starter
  `.claude/settings.json` if the project has none. The copy changes only when
  you rerun `--copy`. The installer keeps a list of the files it placed
  (`.claude/.llm-orchestrator-files`); a rerun removes a listed file the plugin
  no longer ships, but only if you have not changed it.
- **Global instructions:** `./scripts/install.sh --global` adds a short block
  to `~/.claude/CLAUDE.md` so every session knows to look for a project's
  cadence rulebook. It changes nothing in projects without the cadence.

### Wiring hooks for a --copy install

A copy does not turn its hooks on by itself. Either install the same clone as
a plugin, with `/plugin marketplace add /path/to/llm-orchestrator` and
`/plugin install llm-orchestrator@llm-orchestrator`, or add the hooks to
`.claude/settings.json` by hand: the copied `.claude/hooks/hooks.json` has
every entry, with absolute paths, for you to copy under `"hooks"`.

### Other tools

The skills, commands and agent prompts are plain Markdown, so other tools can
read them: copy `skills/`, `commands/` and `templates/` into the tool's config
folder. The hooks work only on Claude Code, and three of them on Codex.

## Settings

Settings are environment variables. Set them in your shell, or in the `env`
block of `.claude/settings.json`.

### Hooks

| Hook | What it does | On by default | Off with `minimal` | Name to turn it off |
|---|---|---|---|---|
| `session-start.sh` | Adds a short note on when skills apply; in a cadence project, the lock check and reply format | yes | stays on, without the recovery note after compaction | `orch-session-start` |
| `user-prompt-submit.sh` | Reminds the assistant of the reply format each turn, in cadence projects only | yes | yes | `orch-user-prompt-submit` |
| `orch-research-gate.sh` | When a request names a library, version or security topic while designing, reminds the assistant to check current docs | yes | yes | `orch-research-gate` |
| `orch-handoff-nudge.sh` | Reminds the assistant once to write a handoff note when the conversation gets long (see `ORCH_CONTEXT_HANDOFF_TOKENS` below) | yes | yes | `orch-handoff-nudge` |
| `guard-no-verify.sh` | Refuses git commands that skip git's hooks or commit signing (`--no-verify` and similar) | yes | yes | `orch-guard` |
| `guard-destructive-git.sh` | Refuses git commands that throw away uncommitted work (`git reset --hard`, `git stash`, `git clean -f`, …) in your main working folder; allowed inside a worktree the plugin created | yes | no | cannot be turned off this way |
| `orch-verify-gate.sh` | The completion check ([what it does](../README.md#what-happens-by-default)) | yes | yes | `orch-verify-gate` |
| `subagent-stop.sh`, `orch-researcher-validator.sh` | Check that a helper agent's report has the expected shape | yes | yes | `orch-subagent-stop`, `orch-researcher-validator` |
| `orch-retry-cap.sh` | Warns when the same action repeats three times in a row | yes | yes | `orch-retry-cap` |
| `orch-worktree-reaper.sh` | Frees a worktree left locked by a helper agent that stopped | yes | yes | `orch-worktree-reaper` |
| `orch-cadence-stop.sh` | Checks the cadence lock at the end of each turn, in cadence projects only | yes | no | `orch-cadence-stop` |
| `orch-task-cleanup.sh` | Removes temporary files of finished tasks | yes | yes | `orch-task-cleanup` |
| `orch-stop.sh` | Deletes old trash and cached research | yes | no | `orch-stop` |
| `skill-telemetry.sh` | Records skill use locally | no (`ORCH_TELEMETRY=1`) | — | `orch-skill-telemetry` |

- **Profiles.** `ORCH_HOOK_PROFILE=standard` is the default.
  `ORCH_HOOK_PROFILE=minimal` turns off the hooks marked above.
  `ORCH_HOOK_PROFILE=strict` makes the report-shape check and the repeat
  breaker block the turn instead of warning (the same as
  `ORCH_STRICT_STATUS=1` and `ORCH_STRICT_RETRY=1`; set either to `0` to keep
  it a warning). The completion check never blocks.
- **Turning off single hooks.** List their names, comma-separated:
  `ORCH_DISABLED_HOOKS=orch-research-gate,orch-handoff-nudge`.

### Escape hatches for the hard guards

The destructive-git guard ignores the profile and the list above, so turning
off a reminder can never turn off the safety guard. Its only off switch is its
own, set by a person in the environment Claude Code starts with:

```
export ORCH_ALLOW_DESTRUCTIVE_GIT=1
```

Putting it in front of the git command itself does not work. The
`--no-verify` guard's switch is `ORCH_ALLOW_NO_VERIFY=1`. The Codex file guard
has no switch; a locked file changes only by
[a ruling](cadence.md#changing-the-rules).

### Other settings

| Setting | What it does |
|---|---|
| `ORCH_CONTEXT_HANDOFF_TOKENS` | The handoff reminder fires once when the conversation passes this many tokens. Default `950000`, a fixed count sized for a 1M-token window: with a smaller window (for example 200k) it never fires unless you lower it, e.g. to `180000` |
| `ORCH_RETRY_CAP=0` | Turns off the repeat breaker. `ORCH_RETRY_CAP_N` sets how many repeats count (default 3) |
| `ORCH_STRICT_RESEARCH=1` | Blocks a malformed research brief instead of warning |
| `ORCH_STRICT_CADENCE_LOCK=1` | Lets the end-of-turn lock check block, once per session |
| `ORCH_SESSION_MAX_CHARS` | Cap on the text added at session start (default 8000) |
| `ORCH_TELEMETRY=1` | Records skill use in `~/.llm-orchestrator/telemetry/` |
| `ORCH_HOME` | Where the plugin keeps its files (default `~/.llm-orchestrator`) |
| `ORCH_HOOK_DRY_RUN=1` | Hooks print what they would do, and do nothing. The guards, the completion check, `orch-stop.sh` and the worktree reaper ignore it |

### Where the plugin keeps its files

Project facts go in the project's own `CLAUDE.md`, and facts for all projects
in `~/.claude/CLAUDE.md`. Everything else is under `~/.llm-orchestrator/`:
lines removed by `/llm-orchestrator:forget` (kept 90 days in `memory/.trash/`),
cached research, per-project research settings and small state files. Folders
are created on first use.

### Optional: statusline

`scripts/statusline.sh` shows the model, the hook profile, and plan and memory
hints. A plugin cannot set the statusline, so add it to your own
`.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash /full/path/to/scripts/statusline.sh" }
}
```

Find the path with
`find ~/.claude/plugins -name statusline.sh -path '*llm-orchestrator*'`; in a
`--copy` install it is `.claude/scripts/statusline.sh`.
