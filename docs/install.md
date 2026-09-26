# Install and update

**Plan in Claude Code. Build with Claude Code or Codex.**

The whole plugin lives in Claude Code: brainstorming, planning, implementation,
review and verification. Codex gets a smaller part from one installer: the
cadence skill, the shared instructions and three small hooks. See
[Codex](codex.md).

- **New install:** install [the plugin](#option-1--claude-code-plugin).
- **Codex:** run [the Codex installer](#codex-setup).
- **Already installed:** follow [Updating to v0.11.0](#updating-to-v0110).

Cadence means the agreed sequence of implementation, independent reviews, fixes,
and verification. It starts only in projects that enable it. Installing the
framework does not turn it on in every repository.

## Codex setup

In your terminal, clone the framework into a folder you plan to keep, add it
to Codex as a plugin, and add the instructions block:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
codex plugin marketplace add "$PWD"
codex plugin add llm-orchestrator@llm-orchestrator
./scripts/install.sh --codex
```

The plugin installs the cadence skill and the three hooks. The installer adds
the instructions block to `~/.codex/AGENTS.md` and nothing else. Open a new
Codex session and run `/hooks`. Review the three hooks and trust them. Codex
only runs a hook you have trusted, and neither command can do that step for
you.

In short, the three hooks are: one that stops the assistant editing a
project's rulebook, one that sends the assistant back once when a reply claims
tests passed and none ran, and one that cleans up temporary files from
finished tasks. None of them prints a message for you. The full picture is on
the [Codex page](codex.md), including how project trust and
`~/.codex/AGENTS.override.md` change what Codex reads.

## Enable cadence in a project

Enabling cadence in a project takes about fifteen minutes and produces three
things: a config file that says how to run your tests, a rulebook for the
project, and a lock that keeps both from changing quietly.

**Step 1 — run the initializer.** Open the project and run:

```text
/llm-orchestrator:cadence-init
```

(The procedure is written out in [the command](../commands/cadence-init.md).)
With Codex, ask the assistant to enable cadence using the scripts in the
cadence skill's `scripts/` folder, following that same procedure; it
proposes the configuration and drafts rulebook text for your approval.

**Step 2 — confirm the config.** The assistant shows you a proposed
`docs/llm-orchestrator/cadence.json`. Check two things: the test command is
the one you actually use, and the folders listed as production code and tests
are right. New projects get `workflow: proportional`; older projects keep their
existing workflow until you migrate them on purpose. If the initializer could
not recognize your stack, it says so and leaves the test command for you to
fill in; until it is filled in, the assistant reports verification as pending
rather than passed.

**Step 3 — write the rulebook.** The initializer creates
`docs/llm-orchestrator/LAWS.md` from a template with `<PLACEHOLDER>` slots:
what the project is, what you promise users, what counts as catastrophic,
serious or mild, your standing orders, and the rulings you have made. A short
filled-in example ships with the skill as
[`laws-example.md`](../skills/cadence/references/laws-example.md). The assistant
may draft wording for you in the conversation; you decide what goes in. The
rulebook is yours, and assistants never edit it on their own.

**Step 4 — finish setup, in this order.** The initializer prints these same
steps for the run it just made:

1. Complete `LAWS.md` with your approved wording. Record the setup itself as
   the first ruling, number one, in the rulings list.
2. In your own terminal, run the `--lock` command the initializer printed. This
   records the finished rulebook and configuration in the lock.
3. Run `git config core.hooksPath .githooks` yourself, once per clone. The
   commit check works only after this.
4. Commit the setup files with the commit command the initializer printed.
   This first commit needs no ruling number in its message, because there is
   no earlier rule it amends; every later change to a protected file does.
5. If the project has CI, add `.githooks/orch-cadence-check.sh --audit HEAD`
   to its pipeline; it covers clones where the hooks were never enabled.

**What lives where.** The framework's shared instructions stay in the plugin.
Your project's rulebook, test commands and verification steps stay in your
project and survive plugin updates; changing them later is a numbered ruling.

## Updating to v0.11.0

### Claude Code plugin

For an installation from this repository's marketplace, run these in your terminal:

```sh
claude plugin marketplace update llm-orchestrator
claude plugin update llm-orchestrator@llm-orchestrator
```

Restart Claude Code and check the installed version in `/plugin`. Updating the
plugin makes the new version available; cadence still needs to be enabled in
each project that should use it.

If you installed with `--link` or `--copy` instead, rerun that installer from an
updated checkout. A `--copy` install is a copy, not a link, so it only changes
when you rerun it.

If your installation currently points to a temporary worktree, run the installer
from a permanent, updated framework checkout before removing the temporary one.
An installation can also stay pinned to a checked-out release tag.

### Codex installation

In your framework checkout, on `main` with your local work saved, run:

```sh
git pull --ff-only
codex plugin add llm-orchestrator@llm-orchestrator
./scripts/install.sh --codex
```

Codex runs the plugin from its own copy, and `codex plugin add` refreshes it.
Then check `/hooks` in a new session: a hook whose definition changed needs
your trust again. If you installed the Codex layer with an earlier
`install.sh --codex`, add the plugin as in [Codex setup](#codex-setup) first;
without it, this run removes nothing. With it, the run removes the skill copy and the hook entries that earlier install
wrote, so each hook runs once. See
[Upgrading from an older install](codex.md#upgrading-from-an-older-install).

The remaining sections cover alternative Claude installations and detailed
settings.

## Option 1 — Claude Code plugin

```
/plugin marketplace add https://github.com/felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

(`/plugin marketplace add` and `/plugin install` are built-in Claude Code commands, not orchestrator commands.)

After install, restart the session. When you restart, the plugin loads automatically — no manual step.

Done when `/plugin list` shows `llm-orchestrator` installed.

## Option 2 — Symlink into your home dir

Clone, then:

```
cd /path/to/llm-orchestrator
./scripts/install.sh --link
```

This creates `~/.claude/llm-orchestrator -> /path/to/llm-orchestrator`. To make Claude Code load it, use the marketplace flow (built-in Claude Code commands):

```
/plugin marketplace add ~/.claude/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

The symlink keeps the install in sync with your local checkout — `git pull` in the original directory updates the plugin in place.

Done when `/plugin list` shows `llm-orchestrator` installed.

## Option 3 — Per-project copy

If you don't want a global install:

```
cd /path/to/llm-orchestrator
./scripts/install.sh --copy ~/myproject
```

This copies `skills/`, `commands/`, `agents/`, `templates/`, `output-styles/`, `hooks/`, `scripts/` (including `scripts/lib/orch-lock.sh`), and this document (to `.claude/docs/install.md`) into `~/myproject/.claude/`. Hook paths in the copied `hooks/hooks.json` are rewritten to absolute — and the installer verifies that every rewritten command path exists on disk before claiming so; if verification fails, the install fails. A starter `settings.json` is seeded from `templates/settings.json` (permissions block plus the ORCH env knobs) unless one already exists.

### Wiring hooks for a `--copy` install

`hooks/hooks.json` uses the **plugin** hook schema (the same one shipped by `.claude-plugin/plugin.json`). Claude Code's per-project `settings.json` uses a slightly different schema — so we don't auto-embed the plugin's hooks block.

Two options:

**A. Install as a plugin (recommended).** Even on a single project, you can install LLM Orchestrator as a plugin via marketplace:
```
/plugin marketplace add /path/to/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```
This uses the plugin schema directly; no settings.json edits needed.

**B. Wire hooks manually in settings.json.** The example below mirrors `hooks/hooks.json` — every command hook across six events. (An earlier version of this section wired 7 of 15 and silently dropped, among others, the destructive-git guard and the verify gate; `tests/test-install.sh` now fails if a shipped hook script or event is missing here.) Add this to `.claude/settings.json`:
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
Replace `/full/path/to/.claude/` with the absolute path to the copied directory. Easier still: the copied `.claude/hooks/hooks.json` already has every path rewritten to absolute, so you can transcribe the entries from there.

Every shipped hook is a script, so the copied `.claude/hooks/hooks.json` is the
whole list. Until 2026-09-21 there was one more, a `type: "prompt"` hook on
`SubagentStop` that judged whether a claimed pass showed real command output. It
is gone; the check that remains is `orch-verify-gate.sh`, described under
"Profiles" and again further down.

## Memory location

By default, memory and saved sessions live in:

```
~/.llm-orchestrator/memory/<project-hash>.md      # project facts
~/.llm-orchestrator/memory/.trash/                # soft-deleted lines, pruned after 90 days
~/.llm-orchestrator/sessions/<project-hash>/      # session-id marker and the worktree registry
~/.claude/CLAUDE.md                               # cross-project facts (/remember --global)
```

Override with `ORCH_HOME=/some/other/path`. The directories are created on first write.

## Verify

```
./scripts/install.sh --check
./tests/validate-skills.sh
```

Both should print OK.

Scope: `--check` validates the **source checkout** it lives in — files present, JSON parseable, every hook command in `hooks/hooks.json` resolving to a script that exists. It cannot be pointed at an installed tree (`install.sh` is not among the files `--copy` writes). A `--copy` install is instead verified at install time: `--copy` fails, rather than printing success, when the installed `hooks.json` does not resolve.

## Profiles

`ORCH_HOOK_PROFILE` is read by each hook script individually — there is no central profile map; the scripts are the source of truth.

```
export ORCH_HOOK_PROFILE=minimal    # most hooks exit immediately (see below)
export ORCH_HOOK_PROFILE=standard   # default — everything active
export ORCH_HOOK_PROFILE=strict     # everything active AND blocking
```

- `minimal` — these hooks exit without acting: protocol reminders (`user-prompt-submit`), research gate, handoff nudge, the `--no-verify` guard, retry cap, Status validators (`subagent-stop`, researcher validator), worktree reaper. SessionStart still loads the `using-orchestrator` core (and the reply format in a cadence-enabled project).
- `standard` (default) — all of the above are active.
- `strict` — everything in `standard`, and the two gradeable checks **block** instead of warning: it implies `ORCH_STRICT_STATUS` and `ORCH_STRICT_RETRY`. To keep one check non-blocking under this profile, set that knob to `0` explicitly — an explicit value always wins over the profile. (Before 2026-08-03 no script branched on the profile at all, so `strict` was accepted and behaved exactly like `standard`.)

Profile-exempt, deliberately:

- `guard-destructive-git.sh` — always on. See "Escape hatches for the hard guards".
- `orch-stop.sh` — retention cleanup (trash + research-cache pruning) runs in every profile.
- `skill-telemetry.sh` — governed by its own opt-in (`ORCH_TELEMETRY=1`, default off), not by profile.
- `orch-verify-gate.sh` — on in `standard` and `strict`, off in `minimal`, and it only ever adds a note for the model, so there is nothing to turn down. Its Codex twin, `codex-verify-gate.sh`, follows the same switches.

Disable individual hooks without changing profile (comma-separated):

```
export ORCH_DISABLED_HOOKS=orch-guard,orch-research-gate
```

Recognized names: `orch-session-start`, `orch-user-prompt-submit`, `orch-guard` (the `--no-verify` guard), `orch-research-gate`, `orch-handoff-nudge`, `orch-skill-telemetry`, `orch-subagent-stop`, `orch-researcher-validator`, `orch-retry-cap`, `orch-worktree-reaper`, `orch-task-cleanup`, `orch-stop`, `orch-cadence-stop`, `orch-verify-gate`, and on Codex `codex-verify-gate`.

One cadence hook is exempt from this list on purpose, because a guard that can be talked off is not a guard: on Codex, the file guard. The other one that runs in cadence mode, the session-start line (`orch-session-start`), is nameable here, and it is inert in any project without a `docs/llm-orchestrator/cadence.json` that says `"enabled": true`, so there is nothing to disable until you opt in.

## Escape hatches for the hard guards

`guard-destructive-git.sh` (blocks `git reset --hard`, `git stash`, `git clean`, and friends — the working-tree-destroying forms) deliberately ignores **both** `ORCH_DISABLED_HOOKS` and `ORCH_HOOK_PROFILE`. That asymmetry is the design, not an oversight: a guard against silently losing uncommitted work must not share an off switch with style hooks, or disabling a nudge quietly disarms the safety layer too. Its only opt-out is its own named variable, set in the hook's environment by a human who means it:

```
export ORCH_ALLOW_DESTRUCTIVE_GIT=1
```

An inline `ORCH_ALLOW_DESTRUCTIVE_GIT=1 git …` prefix in the command being run does **not** disarm the guard — that lands in the child shell's environment, not the hook's.

### Changing the rules

In a project that has opted in, the locked set is that project's laws (`docs/llm-orchestrator/LAWS.md`), its `cadence.json`, its `LOCK.sha256`, its `.claude/settings.json`, `.githooks/commit-msg` and `.githooks/orch-cadence-check.sh`, and the marked `ORCH:LAWS` section of `CLAUDE.md` and `AGENTS.md`. The `Edit(...)` deny rules `cadence-init` writes into `.claude/settings.json` hold the six *files*; the marked section is held by the alarm — the end-of-turn verdict, the session-start line and the `commit-msg` refusal — because an `Edit(path)` rule addresses a whole file and cannot address a section inside one. The rest of `CLAUDE.md` and `AGENTS.md` stays writable, so `/llm-orchestrator:remember`, `/llm-orchestrator:onboard` and `/llm-orchestrator:forget` keep working.

These files change only by a numbered ruling. When the assistant thinks a rule should change, it explains why and shows you the change as a patch file kept outside Git. If you agree, it gives you one command to run in your own terminal:

```
bash <plugin>/skills/cadence/scripts/cadence-ruling.sh <patch-file> "<your wording>"
```

The command works on a private copy of the patch and shows its sha256. It checks that every path the patch touches, renames and deletions included, is protected, that a change to `CLAUDE.md` or `AGENTS.md` stays inside the marked section, that the protected files match `HEAD`, that the patch still applies, and that it adds the next `Ruling <N>` to `LAWS.md`. It asks you to type `ruling <N>`, then applies the patch, re-records the lock with `--lock`, commits with the message `Ruling <N>: <your wording>` (the `commit-msg` hook checks it like any other commit), and runs `--audit HEAD` on the result. If any step fails or you interrupt it, it puts the files and `HEAD` back; if it cannot, it says so and names the files.

It refuses to run in an assistant's shell: when `CLAUDECODE` is set (Claude Code sets it), when `CODEX_THREAD_ID`, `CODEX_SANDBOX` or `CODEX_SANDBOX_NETWORK_DISABLED` is set (names found in the Codex binary, not yet observed in a live Codex shell), or when there is no terminal to read the confirmation from. `--lock` also rewrites an existing lock only when a terminal is attached, and `cadence-init` adds the deny rule `Bash(*cadence-ruling.sh*)`, so Claude Code refuses any command that names it (a test or file name containing that text is refused too). **The known limit.** An assistant that clears those variables and runs the command, or `--lock`, inside a pseudo-terminal (for example with `script` or Python's `pty` module) has a terminal, so these checks do not stop it. Nothing in the plugin prevents that; the commit it makes still appears in the history as a ruling you did not make.

**Upgrading a project set up with an older version.** An older project's `.githooks/orch-cadence-check.sh` still honours the removed `ORCH_CADENCE_UNLOCK` variable, so an assistant could set it and re-record the lock without a terminal. Re-run `/llm-orchestrator:cadence-init`. In an armed project it writes no protected file; it writes an upgrade ruling patch outside the project (the shipped `.githooks/` copies, the current marked block, the missing deny rules, and the next `Ruling <N>` line appended to `LAWS.md`) and prints the one `cadence-ruling.sh` command that applies it. Review the patch, then run that command in your own terminal.

One accepted gap: these hooks resolve the project from `CLAUDE_PROJECT_DIR` (falling back to the working directory) *before* decoding anything, which is what keeps them free for everyone else. A cadence project edited from a session rooted somewhere else is therefore not covered by the hooks — the native deny rules and the git layer still cover it.

### The lock's two layers

**Layer 1 — the native deny rules** in `.claude/settings.json`. Deny beats every hook and every allow rule, in every permission mode including bypass. The `Edit(...)` rules `cadence-init` writes cover the Edit and Write tools, the shell's recognised file commands (`cat`, `head`, `tail`, `sed`) and every shell redirection target, so a careless write to a locked file fails at once and loudly.

This was checked live, not only read; the method, date and results are in [`cadence-evidence.md`](./cadence-evidence.md).

**The sandbox, and what it buys.** With Claude Code's sandbox enabled, those same `Edit` rules merge into an OS-level deny-write list enforced for **every subprocess** — which closes the one gap the rules otherwise state plainly: a script that opens the file itself, without naming it where the permission system can see it. That is the difference between "the agent's own tools are refused" and "nothing running under this session can write that file". Turn it on with `/sandbox` in a session, or with `"sandbox": {"enabled": true}` in `.claude/settings.json`, and re-run the check the way [`cadence-evidence.md`](./cadence-evidence.md) sets it out under its method — the same headless sessions against a throwaway project — to see it on your machine. The plugin never enables it for anyone: a sandbox changes how every command in the session behaves, and that is the user's decision, not an installer's.

**Layer 2 — the alarm**, which names a change rather than preventing one. Four checks, and it is worth knowing when each runs:

| check | when it runs | what it says |
|---|---|---|
| the end-of-turn verdict (`orch-cadence-stop.sh`) | at the end of every turn | whether the lock still matches the tree, as a note to the model; it blocks only under `ORCH_STRICT_CADENCE_LOCK=1`, once per session |
| the session-start line (`session-start.sh`) | at the first turn of every session, including after a compaction | the same verdict again, so a change made in a session nobody watched is the first thing the next one reads |
| `.githooks/commit-msg` | at `git commit`, once `git config core.hooksPath .githooks` has been run in that clone | refuses the commit that carries a lock-set change without a numbered ruling recorded in the laws |
| `orch-cadence-check.sh --audit <rev>` | in CI, on the pushed commit | the same three checks against a commit — the layer that holds when the hook was never routed, or was stepped past |

None of the four blocks a turn by default; set `ORCH_STRICT_CADENCE_LOCK=1` in the environment and the end-of-turn verdict may block once per session, and only for a path that changed after that session's opening snapshot.

Two of the four are live only after a step the init prints rather than takes. The `commit-msg` refusal starts working once this clone's hooks are routed with the line the init prints, and the manifest everything here compares against is only true once the laws' placeholders are filled in and re-locked. The init's order is: fill the placeholders, re-lock in your own terminal, route this clone's hooks (once per clone), commit.

The honest boundary: the lock stops accidental edits and makes deliberate ones visible in the history. A write the deny rules do not stop happens, is named at the end of that turn and at the next session start, and a commit of it is refused unless it also re-records the lock and carries a numbered ruling. It cannot stop an agent determined to fake a ruling: a script the agent runs can rewrite `LAWS.md` and `LOCK.sha256` together and commit with a `Ruling <N>` message, and the `commit-msg` hook accepts that commit. The fake ruling then shows in the history, where you can see you did not make it.

### The CI step

One line closes the gap the git hook cannot: a clone where `core.hooksPath` was never set, or a commit made with the hook stepped past. Run it on the pushed commit — the same line `cadence-init` prints in its recipe:

```
.githooks/orch-cadence-check.sh --audit HEAD
```

It exits non-zero when a locked file changed without a numbered ruling, and it prints what it skipped rather than passing quietly — the landing-evidence check is announced as SKIPPED in CI, because the evidence directory is local to the machine that did the work and the commit-msg hook already read it there.

In a GitHub Actions workflow, on a feature branch, that is three steps — the middle one fetches `main`, which some suites compare against and which a shallow default checkout does not have:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- name: Fetch main (branch-relative checks resolve refs/heads/main)
  if: github.ref != 'refs/heads/main'
  run: git fetch --no-tags origin main:refs/heads/main
- name: Cadence audit
  run: bash .githooks/orch-cadence-check.sh --audit HEAD
```

`fetch-depth: 0` gives `--audit` the parent commit it grades against. The `main` fetch is the step that makes a branch-relative check work on a feature branch, where `main` does not exist locally — `actions/checkout` fetches only the pushed ref. The `if:` guard is not decoration: a push to `main` already has that branch checked out, and git refuses to fetch into the branch it is standing on.

### Re-running the suite at Stop (stronger, and opt-in)

`orch-verify-gate.sh` reads a *record* of what ran — the session transcript.
Claude Code also supports `type: "agent"` hooks, which spawn a subagent with the
full toolkit and up to 50 tool-use turns — an agent hook on `Stop` can run the
suite itself. Re-executing beats reading a record on the one axis that matters:
the agent cannot forge a run that happens after it stops.

It is not shipped on by default because it costs a subagent on every turn, and
for most work the gate's turn-window check is enough. Add it when the repo
warrants the spend:

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

Claude Code has a third kind, `type: "prompt"`: a single cheap-model call with no
tools. It can read a reply and judge it, but it cannot run anything. Only an
agent hook can. This plugin ships neither kind; both are yours to add.

Other knobs:

```
export ORCH_HOME=/some/path             # where plugin memory + research cache live
export ORCH_SESSION_MAX_CHARS=12000     # cap injected context at SessionStart (default 8000)
export ORCH_STRICT_RESEARCH=1           # escalate researcher fidelity warnings to blocks (exit 2)
export ORCH_STRICT_STATUS=1             # block subagent stop on malformed Status block (exit 2)
export ORCH_STRICT_RETRY=1              # block at the retry-storm threshold instead of warning
export ORCH_RETRY_CAP=0                 # disable the retry-storm breaker (default on, warn-only)
export ORCH_ALLOW_NO_VERIFY=1           # let `--no-verify` flags through
```

## Optional: statusline

`statusLine` is **not** a plugin-manifest field, so the shipped `scripts/statusline.sh` (model name + `prof:<hook profile>` + memory/plan indicators) is opt-in. Point your own `.claude/settings.json` at it:

```json
{
  "statusLine": { "type": "command", "command": "bash /full/path/to/scripts/statusline.sh" }
}
```

For a plugin install the script lives under the marketplace cache (`find ~/.claude/plugins -name statusline.sh -path '*llm-orchestrator*'`); for a `--copy` install it is at `.claude/scripts/statusline.sh`. `scripts/install.sh` sits beside it in that same cache, which is where `--global` and `--codex` have to be run from after a plugin install — there is no `./scripts` in the project you opted in.

One seam between the installer and the init is worth knowing before you hit it: on a file whose `ORCH:LAWS` markers are one `START` and *two* `END`s, `install.sh --global` refuses (it compares the counts), while `cadence-init` and the lock accept it and read the first complete pair. Delete the stray `END` and both agree.

## Cross-harness

Claude Code is supported first-class. Codex gets the cadence skill and three small hooks from a Codex plugin (`codex plugin add`), and the shared instructions from `./scripts/install.sh --codex`. What they do is on the [Codex page](codex.md).

The skills, commands and agent prompts are plain markdown, so they work as written instructions anywhere a tool will read them. For Gemini, Copilot or any other harness, copy `skills/`, `commands/` and `templates/` into its config directory by hand and wire the session-start equivalent to `scripts/hooks/session-start.sh`. What you do not get is the enforcement: the hooks and the guards are Claude Code's, and Codex gets the file guard, the completion check and the scratch cleanup only.

The project's own layers are unaffected by any of this. The `.githooks/commit-msg` refusal and `.githooks/orch-cadence-check.sh --audit` live in the repository, not in a harness, so they work from whatever tool made the commit.
