# Install and update

Choose the setup for the tool you use. You can use both in the same project.

- **Claude Code:** install [the plugin](#option-1--claude-code-plugin).
- **Codex:** use [the Codex installer](#codex-setup).
- **Already installed:** follow [Updating to v0.8.0](#updating-to-v080).

Cadence means the agreed sequence of implementation, independent reviews, fixes,
and verification. It starts only in projects that enable it. Installing the
framework does not turn it on in every repository.

## Codex setup

In your terminal, clone the framework into a folder you plan to keep:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
./scripts/install.sh --codex
```

The installer adds the cadence instructions and hooks to your user setup. Hooks
are small programs that run automatically at particular moments: before a tool
edits a protected rule file, after a verification command finishes, or when the
assistant is about to finish. They help check what actually happened.

Open a fresh Codex CLI session and run `/hooks`. Review the definitions and trust
them so Codex can run them. The installer cannot grant that trust for you.
Keep the framework folder in place; installed hooks point to scripts inside it.

Next, [enable cadence in your project](#enable-cadence-in-a-project). The installer
preserves unrelated hooks, your model settings, and your Claude setup. Codex has
its own cadence integration; the Claude plugin's slash commands stay in Claude.
For the recorded test results and the limits of these checks, see
[Codex verification](codex-evidence.md).

## Enable cadence in a project

With **Claude Code**, open the project and run:

```text
/llm-orchestrator:cadence-init
```

With **Codex**, ask your assistant:

> Help me enable cadence in this project using the installed cadence scripts.
> Propose the test commands and project rules for me to review before writing
> them. Include the Codex verification settings and finish the Git hook setup.

The scripts are in `~/.agents/skills/cadence/scripts/`. The setup procedure is
[documented here](../commands/cadence-init.md): detect the project, review the
proposed configuration, run the initializer, fill in the project's rules, and
complete the printed Git hook steps. For Codex, also configure
`codex_verification.mode` in `docs/llm-orchestrator/cadence.json`:
`blocking` asks the assistant to address missing verification before finishing;
`warn` reports the gap. See [the configuration example](codex-evidence.md#activation-contract).

The framework's shared instructions belong in its own repository. A project's
rules, test commands, review records, and app-specific verification steps belong
in that project's repository. Existing project rules are kept when updating the
framework; changes to those rules need a deliberate amendment.

You can optionally use Claude for one of Codex's two independent reviews. It
uses your existing Claude login and defaults to Opus at maximum effort. Follow
[the Claude reviewer guide](codex-provider.md). Grok is not needed.

## Updating to v0.8.0

### Claude Code plugin

For an installation from this repository's marketplace, run these in your terminal:

```sh
claude plugin marketplace update llm-orchestrator
claude plugin update llm-orchestrator@llm-orchestrator
```

Restart Claude Code and check the installed version in `/plugin`. Updating the
plugin makes the new version available; cadence still needs to be enabled in
each project that should use it.

### Codex installation

In your framework checkout, on `main` with your local work saved, run:

```sh
git pull --ff-only
./scripts/install.sh --codex
```

The cadence skill is a copy, so rerun the installer after updating the source.
Open a fresh Codex CLI session and check `/hooks`; new or changed definitions
need your trust. Review the project's verification settings if it used an older
Codex setup. Installation alone does not prove that the hooks have run: ask the
assistant to run an appropriate test through the documented verification runner
and report whether the automatic check accepted the result.

If your installation currently points to a temporary worktree, run the installer
from a permanent, updated framework checkout before removing the temporary one.
An installation can also stay pinned to a checked-out release tag; updating the
Claude plugin and refreshing Codex are separate steps.

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

This copies `skills/`, `commands/`, `agents/`, `templates/`, `output-styles/`, `hooks/`, `workflows/`, `scripts/` (including `scripts/lib/orch-lock.sh`), and this document (to `.claude/docs/install.md`) into `~/myproject/.claude/`. Hook paths in the copied `hooks/hooks.json` are rewritten to absolute — and the installer verifies that every rewritten command path exists on disk before claiming so; if verification fails, the install fails. A starter `settings.json` is seeded from `templates/settings.json` (permissions block plus the ORCH env knobs) unless one already exists.

### Wiring hooks for a `--copy` install

`hooks/hooks.json` uses the **plugin** hook schema (the same one shipped by `.claude-plugin/plugin.json`). Claude Code's per-project `settings.json` uses a slightly different schema — so we don't auto-embed the plugin's hooks block.

Two options:

**A. Install as a plugin (recommended).** Even on a single project, you can install LLM Orchestrator as a plugin via marketplace:
```
/plugin marketplace add /path/to/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```
This uses the plugin schema directly; no settings.json edits needed.

**B. Wire hooks manually in settings.json.** The example below mirrors `hooks/hooks.json` **completely** — all nineteen hook scripts across seven events. (An earlier version of this section wired 7 of 15 and silently dropped, among others, the destructive-git guard and the verify gate; `tests/test-install.sh` now fails if a shipped hook script or event is missing here.) Add this to `.claude/settings.json`:
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
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-destructive-git.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-cadence-unlock.sh" }
        ] },
      { "matcher": "Edit|Write|MultiEdit",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-config-protection.sh" }] },
      { "matcher": "Agent|Task",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-dispatch-model.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "Skill",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/skill-telemetry.sh" }] },
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-evidence-ledger.sh" }] }
    ],
    "PostToolUseFailure": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-evidence-ledger.sh" }] }
    ],
    "SubagentStop": [
      { "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/subagent-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-researcher-validator.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-retry-cap.sh" }
        ] },
      { "matcher": "(^|:)orch-implementer$",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-worktree-reaper.sh" }] }
    ],
    "Stop": [
      { "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-protocol-grader.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-verify-gate.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-retry-cap.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-cadence-stop.sh" }
        ] }
    ]
  }
}
```
Replace `/full/path/to/.claude/` with the absolute path to the copied directory. Easier still: the copied `.claude/hooks/hooks.json` already has every path rewritten to absolute, so you can transcribe the entries from there.

One shipped hook is not a script and is not shown above: the `type: "prompt"` termination-contract hook on `SubagentStop` (matcher `(^|:)orch-implementer$`), which judges whether an implementer's `Verify:` section contains real pasted output. If you want it in a manual wiring, copy its entry verbatim from `.claude/hooks/hooks.json`.

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

- `minimal` — these hooks exit without acting: protocol reminders (`user-prompt-submit`), research gate, handoff nudge, the `--no-verify` guard, config-protection guard, evidence ledger, verify gate, retry cap, Status validators (`subagent-stop`, researcher validator), protocol grader, worktree reaper. SessionStart still loads the protocol core.
- `standard` (default) — all of the above are active.
- `strict` — everything in `standard`, and the four gradeable checks **block** instead of warning: it implies `ORCH_STRICT_PROTOCOL`, `ORCH_STRICT_STATUS`, `ORCH_STRICT_VERIFY` and `ORCH_STRICT_RETRY`. To keep one check non-blocking under this profile, set that knob to `0` explicitly — an explicit value always wins over the profile. (Before 2026-08-03 no script branched on the profile at all, so `strict` was accepted and behaved exactly like `standard`.)

Profile-exempt, deliberately:

- `guard-destructive-git.sh` — always on. See "Escape hatches for the hard guards".
- `orch-stop.sh` — retention cleanup (trash + research-cache pruning) runs in every profile.
- `skill-telemetry.sh` — governed by its own opt-in (`ORCH_TELEMETRY=1`, default off), not by profile.
- the `type: "prompt"` SubagentStop termination-contract hook — evaluated by the platform directly; it cannot read environment variables.

Disable individual hooks without changing profile (comma-separated):

```
export ORCH_DISABLED_HOOKS=orch-guard,orch-research-gate
```

Recognized names: `orch-session-start`, `orch-user-prompt-submit`, `orch-guard` (the `--no-verify` guard), `orch-config-protection`, `orch-research-gate`, `orch-handoff-nudge`, `orch-evidence-ledger`, `orch-skill-telemetry`, `orch-subagent-stop`, `orch-researcher-validator`, `orch-retry-cap`, `orch-worktree-reaper`, `orch-protocol-grader`, `orch-verify-gate`, `orch-stop`, `orch-dispatch-model`, `orch-cadence-stop`.

No cadence hook is exempt from this list. The three that run in cadence mode — the session-start line (`orch-session-start`), the end-of-turn verdict (`orch-cadence-stop`) and the dispatch-model guard (`orch-dispatch-model`) — are each nameable here, and each is inert in any project without a `docs/llm-orchestrator/cadence.json` that says `"enabled": true`, so there is nothing to disable until you opt in. `ORCH_CADENCE_UNLOCK=1` is not an off switch for them: it is the cadence's own unlock, described under "Escape hatches for the hard guards" below.

## Escape hatches for the hard guards

`guard-destructive-git.sh` (blocks `git reset --hard`, `git stash`, `git clean`, and friends — the working-tree-destroying forms) deliberately ignores **both** `ORCH_DISABLED_HOOKS` and `ORCH_HOOK_PROFILE`. That asymmetry is the design, not an oversight: a guard against silently losing uncommitted work must not share an off switch with style hooks, or disabling a nudge quietly disarms the safety layer too. Its only opt-out is its own named variable, set in the hook's environment by a human who means it:

```
export ORCH_ALLOW_DESTRUCTIVE_GIT=1
```

An inline `ORCH_ALLOW_DESTRUCTIVE_GIT=1 git …` prefix in the command being run does **not** disarm the guard — that lands in the child shell's environment, not the hook's.

`guard-config-protection.sh` (blocks edits to settings/hook/guard files) honours `ORCH_HOOK_PROFILE=minimal` and `ORCH_DISABLED_HOOKS=orch-config-protection`, and has its own explicit hatch:

```
export ORCH_ALLOW_CONFIG_EDIT=1
```

`ORCH_CADENCE_UNLOCK=1` is not a hook hatch at all — it is the cadence's own unlock, and it belongs on this page because people look for it here. In a project that has opted in, the locked set is that project's laws (`docs/llm-orchestrator/LAWS.md`), its `cadence.json`, its `LOCK.sha256`, its `.claude/settings.json`, `.githooks/commit-msg` and `.githooks/orch-cadence-check.sh`, and the marked `ORCH:LAWS` section of `CLAUDE.md` and `AGENTS.md`. The `Edit(...)` deny rules `cadence-init` writes into `.claude/settings.json` hold the six *files*; the marked section is held by the alarm — the end-of-turn verdict, the session-start line and the `commit-msg` refusal — because an `Edit(path)` rule addresses a whole file and cannot address a section inside one. Either way an amendment has to be able to rewrite them on purpose. Four programs read the variable: `cadence-init`, which will otherwise keep a file it would have replaced; `orch-cadence-check.sh --lock`, which will otherwise refuse to overwrite an existing manifest; the dispatch-model guard, which stands down for the session; and the Codex adapter, which does the same. The rest of `CLAUDE.md` and `AGENTS.md` stays writable either way, so `/llm-orchestrator:remember`, `/llm-orchestrator:onboard` and `/llm-orchestrator:forget` keep working.

The unlock is one variable, and it is deliberately awkward to make permanent:

```
ORCH_CADENCE_UNLOCK=1 claude
```

Set it in the environment for the one session that needs it — **never in a settings file**. If `.claude/settings.json`, `.claude/settings.local.json` or `~/.claude/settings.json` contains the string `ORCH_CADENCE_UNLOCK`, the unlock is refused, the run names the file that refused it, and the lock stands: a persisted unlock is a disarmed lock in every future session, and it would be invisible from inside the sessions it disarmed. `orch-cadence-check.sh --lock` and the dispatch-model guard both refuse on those terms, and they read that same set of three files.

One more hook belongs to the same rule, and it reads no variable: `guard-cadence-unlock.sh` refuses, in cadence mode, a Bash command whose own text *names* `ORCH_CADENCE_UNLOCK`, `ORCH_DISABLED_HOOKS`, `ORCH_HOOK_PROFILE` or `ORCH_ALLOW_` — whatever the verb, because it is a mention rule and not an assignment grammar, so no spelling of an assignment can slip past a pattern that describes none. These switches are yours, set in your shell at launch; an assignment inside a command an agent is running would let the turn arrange the switch that binds it. The accepted cost is that an agent may not set, read (`echo $ORCH_CADENCE_UNLOCK`), search for or mention one of the four inside a cadence project — the refusal says so and says to do it in your own shell — and the residual it leaves is a name assembled at runtime or split by a quote, which the alarm names afterwards.

The Codex adapter scans a different set, because on that harness a persisted variable would not live in a Claude Code settings file: `~/.codex/config.toml`, the project's `.codex/config.toml`, and the project's `.claude/settings.json` — the last one because a single project is often opened from both tools. And the consequence there is blunter than on Claude Code: with the unlock set and none of those three files carrying the string, the adapter stops reading commands for the rest of that session, so it refuses nothing at all until the session ends — not just the edit you meant to make. Amend, then start a fresh session without the variable.

The amendment path, rather than the unlock alone, is a numbered ruling: make the change under the unlock, re-run `--lock` to re-record the manifest, and commit with `Ruling <N>` in the message so the git layer can see the amendment.

One accepted gap: these hooks resolve the project from `CLAUDE_PROJECT_DIR` (falling back to the working directory) *before* decoding anything, which is what keeps them free for everyone else. A cadence project edited from a session rooted somewhere else is therefore not covered by the hooks — the native deny rules and the git layer still cover it.

### The lock's two layers

**Layer 1 — the native deny rules** in `.claude/settings.json`. Deny beats every hook and every allow rule, in every permission mode including bypass. The `Edit(...)` rules `cadence-init` writes cover the Edit and Write tools, the shell's recognised file commands (`cat`, `head`, `tail`, `sed`) and every shell redirection target, so a careless write to a locked file fails at once and loudly.

That was checked live rather than only read (2026-09-06, Claude Code 2.1.263, six headless sessions against a throwaway project carrying exactly these rules): the Edit tool, the Write tool, `echo … > <locked file>`, `cp notes.md <locked file>` and `sed -i … <locked file>` were all refused and the file's hash never moved, while a control edit on an ordinary file went through — so the refusals are the deny rules, not a blanket denial. `cp` is more than the documentation promises. The full method and table: [`cadence-evidence.md`](./cadence-evidence.md).

**The sandbox, and what it buys.** With Claude Code's sandbox enabled, those same `Edit` rules merge into an OS-level deny-write list enforced for **every subprocess** — which closes the one gap the rules otherwise state plainly: a script that opens the file itself, without naming it where the permission system can see it. That is the difference between "the agent's own tools are refused" and "nothing running under this session can write that file". Turn it on with `/sandbox` in a session, or with `"sandbox": {"enabled": true}` in `.claude/settings.json`, and re-run the check the way [`cadence-evidence.md`](./cadence-evidence.md) sets it out under its method — the same headless sessions against a throwaway project — to see it on your machine. The plugin never enables it for anyone: a sandbox changes how every command in the session behaves, and that is the user's decision, not an installer's.

**Layer 2 — the alarm**, which names a change rather than preventing one. Four checks, and it is worth knowing when each runs:

| check | when it runs | what it says |
|---|---|---|
| the end-of-turn verdict (`orch-cadence-stop.sh`) | when a turn ends, in cadence mode | that the lock no longer matches the tree, in the same turn the change happened |
| the session-start line (`session-start.sh`) | at the first turn of every session, including after a compaction | the same verdict again, so a change made in a session nobody watched is the first thing the next one reads |
| `.githooks/commit-msg` | at `git commit`, once `git config core.hooksPath .githooks` has been run in that clone | refuses the commit that carries a lock-set change without a numbered ruling recorded in the laws |
| `orch-cadence-check.sh --audit <rev>` | in CI, on the pushed commit | the same three checks against a commit — the layer that holds when the hook was never routed, or was stepped past |

None of the four blocks a turn by default; set `ORCH_STRICT_CADENCE_LOCK=1` in the environment and the end-of-turn verdict may block once per session, and only for a path that changed after that session's opening snapshot.

Two of the four are live only after a step the init prints rather than takes. The `commit-msg` refusal starts working once this clone's hooks are routed with the line the init prints, and the manifest everything here compares against is only true once the laws' placeholders are filled in and re-locked. The init's order is: fill the placeholders, re-lock under the unlock, route this clone's hooks (once per clone), commit.

The honest boundary is one sentence: a write the deny rules do not stop happens, is named at the end of that turn and at the next session start, and is refused at the commit.

A shell guard — a hook that read each Bash command's text and refused the ones naming a locked path — was built and then removed. Deciding what a command does by reading it cannot be made tight (a computed path, an archive, an interpreter or an unlisted verb names nothing the text can see), and everything it did catch the alarm already names.

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

The evidence ledger reads a *record* of what ran. Claude Code also supports
`type: "agent"` hooks, which spawn a subagent with the full toolkit and up to 50
tool-use turns — an agent hook on `Stop` can run the suite itself. Re-executing
beats reading a record on the one axis that matters: the agent cannot forge a
run that happens after it stops.

It is not shipped on by default because it costs a subagent on every turn, and
for most work the ledger's turn-window check is enough. Add it when the repo
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

Note the difference from the `type: "prompt"` hook this plugin already ships on
`SubagentStop`: a prompt hook is a single cheap-model call with no tools. It can
judge whether a `Verify:` block contains pasted output or an assertion — which is
exactly what it is used for here — but it cannot execute anything. Only an agent
hook can.

Other knobs:

```
export ORCH_HOME=/some/path             # where plugin memory + research cache live
export ORCH_SESSION_MAX_CHARS=12000     # cap injected context at SessionStart (default 8000)
export ORCH_STRICT_RESEARCH=1           # escalate researcher fidelity warnings to blocks (exit 2)
export ORCH_STRICT_STATUS=1             # block subagent stop on malformed Status block (exit 2)
export ORCH_STRICT_PROTOCOL=1           # block controller Stop on malformed reply shape (exit 2)
export ORCH_STRICT_VERIFY=1             # block a Changed: whose Verify: has no green ledger record this turn (exit 2)
export ORCH_EVIDENCE_MARKER=1           # append an inert [orch-evidence ...] line to verify output (off by default)
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

Claude Code is supported first-class. For Gemini and Copilot there are still no mirrors: copy `skills/`, `commands/`, `templates/` into the harness's config directory by hand and wire the session-start equivalent to `scripts/hooks/session-start.sh`.

For Codex, one command installs what exists:

```
./scripts/install.sh --codex
```

It copies the cadence skill to `~/.agents/skills/cadence`, renders the shared pointer block into `~/.codex/AGENTS.md`, and merges file-protection and evidence hooks into `~/.codex/hooks.json`. Existing unrelated hooks survive; re-running does not duplicate these handlers. Model settings and Claude hooks are unchanged. Review and trust new definitions using `/hooks` in a fresh Codex CLI session before expecting them to execute.

The evidence hooks activate only when the enabled project's `cadence.json` also sets `codex_verification.mode` to `blocking` or `warn`. They record actual command outcomes and source fingerprints, check completion after observed code changes, and write native-agent receipts. See [Codex evidence](codex-evidence.md) for the schema, honest pending outcomes, and coverage limits. Optional external Claude reviews use [the provider runner](codex-provider.md); Grok is not required. These additions do not port all Claude protocol hooks.

**What the Codex layer actually is.** The adapter (`scripts/hooks/codex-cadence-adapter.sh`) is Codex's deny rules for the locked files and nothing more: a Bash command or an `apply_patch` header that names a locked file and is not one plain read is refused with exit 2 and the way out printed. It guards no directories, no marked section, no symlinks and no path assembled at runtime — Codex has no native path-deny for an arbitrary file, so this hook is standing in for layer 1, not adding a layer. The git `commit-msg` hook and `orch-cadence-check.sh --audit` carry the rest, exactly as they do on Claude Code.

**What it refuses that Claude Code's deny rules do not.** The adapter reads raw command text, not tokens, so it is deliberately blunt in three places, and each refusal prints its remedy:

- A locked file inside a pipeline or a redirection is refused **even when it is only being read** — `cat <locked file> | jq .` does not get through. Read it as `cat <locked file>` on its own line.
- A multi-line command that names a locked file anywhere in it is refused, for the same reason: a newline is just another operator to a text scan.
- With no `python3` on the `PATH` the hook cannot parse the payload at all, so it fails closed: any call naming a locked file is refused whatever the verb, and it says so.

The way out of all three is the same as on Claude Code: read the file from your own shell, or start the session with `ORCH_CADENCE_UNLOCK=1` in its environment when you mean to amend it.

Hook behavior is grounded in the current [Codex hook contract](https://learn.chatgpt.com/docs/hooks). Matchers select tool names; the adapter inspects patch headers itself. Some tool paths can bypass hooks, unknown response shapes do not prove success, and local fixtures do not establish live trusted-hook execution. Verify the user's installed runtime separately. Git checks remain an additional layer and require committed configuration plus hook routing.
