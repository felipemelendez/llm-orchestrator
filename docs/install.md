# Install, update and settings

This page covers installing the plugin on Claude Code, updating it, turning the
cadence on in a project, and every setting. For Codex, see [Codex](codex.md).

## Requirements

Claude Code, Bash, Git and Python 3. The visual brainstorming panel also needs
Node.js.

## Install on Claude Code

Run these one at a time inside Claude Code:

```text
/plugin marketplace add https://github.com/felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code. The plugin is installed when `/plugin` lists
`llm-orchestrator`. Installing does not turn the cadence on anywhere; you do
that per project (below).

Other ways to install (a symlink, a copy inside one project, or a checkout for
development) are under [Other ways to install](#other-ways-to-install).

## Update

Publishing a release does not update installed copies. In your terminal:

```sh
claude plugin marketplace update llm-orchestrator
claude plugin update llm-orchestrator@llm-orchestrator
```

Restart Claude Code and check the version in `/plugin`. For a `--link` or
`--copy` install, rerun that installer from an updated checkout. For Codex, see
[Codex: Update](codex.md#update).

### Upgrading to 0.12.0

- **Workflow.** A project whose `docs/llm-orchestrator/cadence.json` has no
  `workflow`, or `"workflow": "legacy"`, now gets a one-line error instead of
  running. Set `"workflow": "proportional"`. In an armed project that file is
  protected, so make the change through a ruling (see
  [Changing the rules](#changing-the-rules)).
- **Armed projects set up with an older version.** Their git hooks still honour
  the removed `ORCH_CADENCE_UNLOCK` switch. Re-run
  `/llm-orchestrator:cadence-init`: in an armed project it changes no protected
  file, writes an upgrade patch outside the project, and prints the one
  `cadence-ruling.sh` command that applies it. Review the patch, then run that
  command in your own terminal.
- **Codex.** The skills and hooks now come from the Codex plugin. See
  [Upgrading from an older install](codex.md#upgrading-from-an-older-install).
- **`--copy` installs** now keep a record of what they place. The first rerun
  after upgrading removes nothing and lists the files the plugin no longer
  ships, for you to delete.
- `ORCH_CADENCE_UNLOCK` and `ORCH_ALLOW_CONFIG_EDIT` no longer do anything;
  remove them from your shell setup.

## Enable cadence in a project

The cadence is a set of project rules that matches the amount of review to the
risk of a change (Simple, Standard or Full). Turning it on takes about fifteen
minutes and gives the project three things: a config that says how to run its
tests, a rulebook, and a lock that keeps both from changing quietly.

1. **Run the initializer.** Open the project and run
   `/llm-orchestrator:cadence-init`. With Codex, ask the assistant to enable
   the cadence using the scripts in the cadence skill's `scripts/` folder; the
   steps are the same.
2. **Confirm the config.** The assistant shows a proposed
   `docs/llm-orchestrator/cadence.json`. Check that the test command is the one
   you use, and that the folders listed as production code and tests are right.
   If it could not find a test command, it says so; until you add one, the
   assistant reports verification as pending, not passed.
3. **Write the rulebook.** The initializer creates
   `docs/llm-orchestrator/LAWS.md` from a template with `<PLACEHOLDER>` slots:
   what the project is, what you promise its users, what counts as
   catastrophic, serious or mild, your standing orders and your rulings. A
   filled-in example ships as
   [`laws-example.md`](../skills/cadence/references/laws-example.md). The
   assistant can draft wording in the conversation; you decide what goes in,
   and it never edits the file itself.
4. **Finish setup, in this order.** The initializer prints these steps for the
   run it just made:
   1. Fill in every placeholder in `LAWS.md`. Record the setup itself as ruling
      one in its rulings list.
   2. In your own terminal, run the `--lock` command it printed. This records
      the finished rulebook and config in the lock.
   3. Run `git config core.hooksPath .githooks` once in each clone. The commit
      check works only after this.
   4. Commit the setup files. This first commit needs no ruling number.
   5. If the project has CI, add the [CI step](#the-ci-step).

Your rulebook, config and test commands live in your project and survive
plugin updates. After setup, changing them is a numbered ruling.

## Changing the rules

In an enabled project, these files are locked: `docs/llm-orchestrator/LAWS.md`,
`cadence.json`, `LOCK.sha256`, `.claude/settings.json`, `.githooks/commit-msg`,
`.githooks/orch-cadence-check.sh`, and the marked `ORCH:LAWS` section of
`CLAUDE.md` and `AGENTS.md`. The rest of `CLAUDE.md` and `AGENTS.md` stays
writable, so `/llm-orchestrator:remember`, `/llm-orchestrator:onboard` and
`/llm-orchestrator:forget` keep working.

They change only by a numbered ruling. When the assistant thinks a rule should
change, it explains why and gives you the change as a patch file kept outside
Git. If you agree, run this in your own terminal:

```sh
bash <plugin>/skills/cadence/scripts/cadence-ruling.sh <patch-file> "<your wording>"
```

The command checks that the patch touches only locked files (and only the
marked section of `CLAUDE.md` or `AGENTS.md`), that the locked files match
`HEAD`, that the patch still applies, and that it adds the next `Ruling <N>` to
`LAWS.md`. It asks you to type `ruling <N>`, then applies the patch, re-records
the lock with `--lock`, commits `Ruling <N>: <your wording>`, and runs
`--audit HEAD` on the result. If a step fails or you interrupt it, it puts
everything back.

It refuses to run inside an assistant's shell: when `CLAUDECODE`,
`CODEX_THREAD_ID`, `CODEX_SANDBOX` or `CODEX_SANDBOX_NETWORK_DISABLED` is set,
or when there is no terminal to type into. `--lock` also rewrites an existing
lock only when a terminal is attached, and the initializer adds the deny rule
`Bash(*cadence-ruling.sh*)`, so Claude Code refuses any command that names it.

**The known limit.** An assistant that clears those variables and runs the
command, or `--lock`, inside a pseudo-terminal (for example with `script` or
Python's `pty` module) has a terminal, so these checks do not stop it. The
commit it makes still shows in the history as a ruling you did not make.

## The cadence lock

### The lock's two layers

**Layer 1 — deny rules.** The initializer writes `Edit(...)` deny rules into
`.claude/settings.json` for `LAWS.md`, `cadence.json`, `LOCK.sha256`,
`.claude/settings.json` and `.githooks/`. Deny beats every hook and allow rule,
in every permission mode. The rules cover the Edit and Write tools, the shell
file commands Claude Code recognises (`cat`, `head`, `tail`, `sed`) and every
shell redirection, so a careless write fails at once. How this was checked:
[cadence-evidence.md](cadence-evidence.md).

With Claude Code's sandbox on, the same rules also bind every subprocess,
including a script that opens the file without naming it. Turn it on with
`/sandbox` in a session, or `"sandbox": {"enabled": true}` in
`.claude/settings.json`. The plugin never turns it on for you, because it
changes how every command in the session behaves.

**Layer 2 — the commit hook.** `.githooks/commit-msg` refuses a commit that
changes a locked file without a numbered ruling in the laws. It works only in
clones where `git config core.hooksPath .githooks` has been run.

Three more checks report a change rather than prevent it:

| Check | When it runs | What it does |
|---|---|---|
| End-of-turn verdict (`orch-cadence-stop.sh`) | end of every turn | tells the assistant whether the lock still matches; blocks once per session only with `ORCH_STRICT_CADENCE_LOCK=1` |
| Session-start line (`session-start.sh`) | start of every session, and after a compaction | repeats the verdict, so a change nobody watched is the first thing the next session reads |
| `orch-cadence-check.sh --audit <rev>` | in CI | the commit check, against a pushed commit, for clones whose hooks were never turned on |

### The CI step

Run this on the pushed commit; it is the same line the initializer prints:

```
.githooks/orch-cadence-check.sh --audit HEAD
```

It exits non-zero when a locked file changed without a numbered ruling, and it
names any check it skipped instead of passing quietly. In GitHub Actions, on a
feature branch:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- name: Fetch main
  if: github.ref != 'refs/heads/main'
  run: git fetch --no-tags origin main:refs/heads/main
- name: Cadence audit
  run: bash .githooks/orch-cadence-check.sh --audit HEAD
```

`fetch-depth: 0` gives the audit the parent commit to compare against. The
`main` fetch lets branch-relative checks work on a feature branch; the `if:`
skips it on `main`, where git refuses to fetch into the checked-out branch.

### What the lock cannot stop

The lock stops accidental edits and makes deliberate ones visible. A write the
deny rules miss (for example, by a script the assistant runs) still happens; it
is named at the end of that turn and at the next session start, and a commit of
it is refused unless it also re-records the lock and carries a numbered ruling.
It cannot stop an assistant set on faking a ruling: a script can rewrite
`LAWS.md` and `LOCK.sha256` together and commit with a `Ruling <N>` message,
which the commit hook accepts. That fake ruling then shows in the history.

The hooks find the project from the session's folder. A cadence project edited
from a session started somewhere else is not covered by the hooks; the deny
rules and the git layer still cover it.

## Settings

Settings are environment variables. Set them in your shell or in the `env`
block of `.claude/settings.json`.

### Hook profiles

```
export ORCH_HOOK_PROFILE=minimal    # most hooks off
export ORCH_HOOK_PROFILE=standard   # default
export ORCH_HOOK_PROFILE=strict     # standard, and two checks block instead of warn
```

- `minimal` turns off the per-turn reminder, the research gate, the handoff
  nudge, the `--no-verify` guard, the subagent checks, the retry breaker, the
  worktree reaper, the completion check and the task-scratch cleanup. Session
  start still loads the plugin's core note.
- `strict` makes a malformed or empty subagent report and a repeated-action
  loop block the turn. It is the same as setting `ORCH_STRICT_STATUS=1` and
  `ORCH_STRICT_RETRY=1`; set either to `0` to keep that one as a warning.

Not affected by the profile: the destructive-git guard (see
[below](#escape-hatches-for-the-hard-guards)), the retention pruner
(`orch-stop.sh`), and skill telemetry, which has its own switch. The completion
check never blocks in any profile.

### Turning off single hooks

```
export ORCH_DISABLED_HOOKS=orch-research-gate,orch-handoff-nudge
```

Names: `orch-session-start`, `orch-user-prompt-submit`, `orch-guard` (the
`--no-verify` guard), `orch-research-gate`, `orch-handoff-nudge`,
`orch-skill-telemetry`, `orch-subagent-stop`, `orch-researcher-validator`,
`orch-retry-cap`, `orch-worktree-reaper`, `orch-task-cleanup`, `orch-stop`,
`orch-cadence-stop`, `orch-verify-gate`, and on Codex `codex-verify-gate`. The
destructive-git guard and the Codex file guard cannot be turned off this way.

### Escape hatches for the hard guards

`guard-destructive-git.sh` blocks the git commands that throw away uncommitted
work (`git reset --hard`, `git stash`, `git clean -f`, and similar) on the
shared checkout. It ignores both `ORCH_DISABLED_HOOKS` and `ORCH_HOOK_PROFILE`
on purpose, so turning off a reminder can never turn off the safety guard. Its
only off switch is its own, set by a person in the hook's environment:

```
export ORCH_ALLOW_DESTRUCTIVE_GIT=1
```

Putting `ORCH_ALLOW_DESTRUCTIVE_GIT=1` in front of the git command itself does
not work; that sets it for the command, not for the hook. The `--no-verify`
guard's switch is `ORCH_ALLOW_NO_VERIFY=1`.

The Codex file guard has no switch. A locked file changes only by
[a ruling](#changing-the-rules).

### Other settings

```
export ORCH_STRICT_STATUS=1             # block a malformed or empty subagent report
export ORCH_STRICT_RETRY=1              # block at the repeated-action limit instead of warning
export ORCH_RETRY_CAP=0                 # turn off the repeated-action breaker (on by default, warns)
export ORCH_RETRY_CAP_N=3               # how many repeats count as a loop (default 3)
export ORCH_STRICT_RESEARCH=1           # block a malformed research brief
export ORCH_STRICT_CADENCE_LOCK=1       # let the end-of-turn lock verdict block, once per session
export ORCH_CONTEXT_HANDOFF_TOKENS=950000  # when to remind about a handoff note (default 950000)
export ORCH_SESSION_MAX_CHARS=8000      # cap on the text added at session start (default 8000)
export ORCH_TELEMETRY=1                 # record skill use locally (off by default)
export ORCH_HOME=/some/path             # where the plugin keeps its files
export ORCH_HOOK_DRY_RUN=1              # hooks print what they would do, and do nothing
```

`ORCH_HOOK_DRY_RUN` is for tuning before you turn a strict switch on. The
guards, the completion check, the retention pruner and the worktree reaper
ignore it.

### Where the plugin keeps its files

```
~/.llm-orchestrator/memory/<project-hash>.md   # research settings for a project
~/.llm-orchestrator/memory/.trash/             # lines removed by /llm-orchestrator:forget, kept 90 days
~/.llm-orchestrator/sessions/<project-hash>/   # session marker and the worktree registry
~/.llm-orchestrator/research/                  # cached research results
~/.claude/CLAUDE.md                            # facts /llm-orchestrator:remember saves for all projects
```

Project facts go in the project's own `CLAUDE.md`. Set `ORCH_HOME` to move the
`~/.llm-orchestrator` folder. Folders are created on first use.

### Optional: statusline

The plugin ships `scripts/statusline.sh`, which shows the model, the hook
profile and plan and memory hints. A plugin cannot set the statusline, so add
it to your own `.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash /full/path/to/scripts/statusline.sh" }
}
```

For a plugin install, find the path with
`find ~/.claude/plugins -name statusline.sh -path '*llm-orchestrator*'`. For a
`--copy` install it is `.claude/scripts/statusline.sh`.

### Optional: re-run the tests at Stop

The completion check reads a record of what ran. Claude Code also supports
`type: "agent"` hooks, which start a subagent that can run the tests itself
after the turn ends, so the result cannot be faked. It is not shipped because
it costs a subagent every turn. To add it:

```jsonc
// .claude/settings.json
{
  "hooks": {
    "Stop": [
      { "hooks": [
        { "type": "agent",
          "prompt": "The assistant has finished a turn. If its final message contains a 'Changed:' block, run this project's test suite and report whether it passes. Return {\"ok\": true} if it passes or if there was no Changed: block. Return {\"ok\": false, \"reason\": \"...\"} with the failing output if it does not.",
          "timeout": 300 }
      ] }
    ]
  }
}
```

A `type: "prompt"` hook is a single model call with no tools: it can judge a
reply but cannot run anything. The plugin ships neither kind.

## Other ways to install

Each of these starts from a clone:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
```

### Run from a checkout (development)

```sh
claude --plugin-dir "$(pwd)"
```

Claude Code reads plugin files once at startup. After editing, restart Claude
Code; `/clear` is not enough.

### Symlink

```sh
./scripts/install.sh --link
```

This creates `~/.claude/llm-orchestrator`, pointing at your checkout. Then, in
Claude Code:

```text
/plugin marketplace add ~/.claude/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

`git pull` in the checkout updates the plugin.

### Per-project copy

```sh
./scripts/install.sh --copy ~/myproject
```

This copies the skills, commands, agents, templates, output style, hooks and
scripts into `~/myproject/.claude/`, plus this page as
`.claude/docs/install.md`. Hook paths in the copied `hooks/hooks.json` are made
absolute, and the install fails if any of them does not exist. A starter
`.claude/settings.json` is added from `templates/settings.json` unless one
exists.

The installer records every file it places, with a SHA-256 of its content, in
`.claude/.llm-orchestrator-files`. A later `--copy` removes a recorded file the
plugin no longer ships, but only while its content is unchanged; a file you
edited is kept and listed. Nothing outside the record is touched. Without
`shasum` or `sha256sum`, no record is written and nothing is removed.

A copy is not a link: it changes only when you rerun `--copy`.

#### Wiring hooks for a --copy install

A copy does not register the hooks by itself. Either install the same checkout
as a plugin, which needs no settings changes:

```text
/plugin marketplace add /path/to/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Or add the hooks to `.claude/settings.json` by hand. This matches
`hooks/hooks.json`; replace `/full/path/to/.claude/` with the copied folder's
absolute path, or copy the entries from `.claude/hooks/hooks.json`, where the
paths are already absolute:

```jsonc
{
  "env": { "ORCH_HOOK_PROFILE": "standard" },
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|clear|compact|resume",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/session-start.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/user-prompt-submit.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-research-gate.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-handoff-nudge.sh" }
        ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-no-verify.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-destructive-git.sh" }
        ] }
    ],
    "PostToolUse": [
      { "matcher": "Skill",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/skill-telemetry.sh" }] }
    ],
    "SubagentStop": [
      { "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/subagent-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-verify-gate.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-researcher-validator.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-retry-cap.sh" }
        ] },
      { "matcher": "(^|:)orch-implementer$",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-worktree-reaper.sh" }] }
    ],
    "Stop": [
      { "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-verify-gate.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-cadence-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-retry-cap.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-task-cleanup.sh" }
        ] }
    ]
  }
}
```

### The global instructions block

```sh
./scripts/install.sh --global
```

Adds the short cadence instructions block to `~/.claude/CLAUDE.md`, so a
session started anywhere knows to look for a project's rulebook. It changes
nothing in projects that never enable the cadence. After a plugin install,
run it from the plugin's folder under `~/.claude/plugins`.

### Other tools

The skills, commands and agent prompts are plain Markdown, so any tool that
reads instructions can use them: copy `skills/`, `commands/` and `templates/`
into its config folder and point its session-start step at
`scripts/hooks/session-start.sh`. The hooks are not included; only Claude Code
gets them all, and Codex gets three ([Codex](codex.md)). The git layer
(`.githooks/commit-msg` and `--audit` in CI) works whichever tool made the
commit.

## Check your install

From a checkout:

```sh
./scripts/install.sh --check
./tests/validate-skills.sh
```

`--check` prints `LLM Orchestrator check: OK` when the checkout is complete,
and lists which layers are present on this machine. It checks the checkout it
lives in, not an installed copy; a `--copy` install is checked when it is made.

If `install.sh --global` refuses a file whose `ORCH:LAWS` markers are one
`START` and two `END`s, delete the extra `END` line and rerun.
