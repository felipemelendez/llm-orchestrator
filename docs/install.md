# Install

Three ways to get LLM Orchestrator running.

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

**B. Wire hooks manually in settings.json.** The example below mirrors `hooks/hooks.json` **completely** — all sixteen hook scripts across seven events. (An earlier version of this section wired 7 of 16 and silently dropped, among others, the destructive-git guard and the verify gate; `tests/test-install.sh` now fails if a shipped hook script or event is missing here.) Add this to `.claude/settings.json`:
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
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-handoff-nudge.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-skill-nudge.sh" }
        ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-no-verify.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-destructive-git.sh" }
        ] },
      { "matcher": "Edit|Write|MultiEdit",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-config-protection.sh" }] }
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
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-retry-cap.sh" }
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

Recognized names: `orch-session-start`, `orch-user-prompt-submit`, `orch-guard` (the `--no-verify` guard), `orch-config-protection`, `orch-research-gate`, `orch-handoff-nudge`, `orch-skill-nudge`, `orch-evidence-ledger`, `orch-skill-telemetry`, `orch-subagent-stop`, `orch-researcher-validator`, `orch-retry-cap`, `orch-worktree-reaper`, `orch-protocol-grader`, `orch-verify-gate`, `orch-stop`.

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

For a plugin install the script lives under the marketplace cache (`find ~/.claude/plugins -name statusline.sh -path '*llm-orchestrator*'`); for a `--copy` install it is at `.claude/scripts/statusline.sh`.

## Cross-harness

Claude Code is supported first-class; there are no Codex / Gemini / Copilot mirrors today. You can copy `skills/`, `commands/`, `templates/` into another harness's config directory by hand and wire the session-start equivalent to `scripts/hooks/session-start.sh`.
