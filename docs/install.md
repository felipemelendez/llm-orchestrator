# Install

Three ways to get LLM Orchestrator running.

## Option 1 — Claude Code plugin

```
/plugin marketplace add https://github.com/<your-org>/llm-orchestrator
/plugin install llm-orchestrator
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
/plugin install llm-orchestrator
```

The symlink keeps the install in sync with your local checkout — `git pull` in the original directory updates the plugin in place.

Done when `/plugin list` shows `llm-orchestrator` installed.

## Option 3 — Per-project copy

If you don't want a global install:

```
cd /path/to/llm-orchestrator
./scripts/install.sh --copy ~/myproject
```

This copies `skills/`, `commands/`, `agents/`, `templates/`, `output-styles/`, `hooks/`, and `scripts/` (including `scripts/lib/orch-lock.sh`) into `~/myproject/.claude/`. Hook paths in `hooks/hooks.json` are rewritten to absolute. A starter `settings.json` is generated.

### Wiring hooks for a `--copy` install

`hooks/hooks.json` uses the **plugin** hook schema (the same one shipped by `.claude-plugin/plugin.json`). Claude Code's per-project `settings.json` uses a slightly different schema — so we don't auto-embed the plugin's hooks block.

Two options:

**A. Install as a plugin (recommended).** Even on a single project, you can install LLM Orchestrator as a plugin via marketplace:
```
/plugin marketplace add /path/to/llm-orchestrator
/plugin install llm-orchestrator
```
This uses the plugin schema directly; no settings.json edits needed.

**B. Wire hooks manually in settings.json.** Add this to `.claude/settings.json`:
```jsonc
{
  "env": { "ORCH_HOOK_PROFILE": "standard" },
  "hooks": {
    "SessionStart": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/session-start.sh" }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/user-prompt-submit.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-research-gate.sh" }
        ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-no-verify.sh" }] }
    ],
    "SubagentStop": [
      { "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/subagent-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-researcher-validator.sh" }
        ] }
    ],
    "Stop": [
      { "matcher": "*",
        "hooks": [
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-stop.sh" },
          { "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-protocol-grader.sh" }
        ] }
    ]
  }
}
```
Replace `/full/path/to/.claude/` with the absolute path to the copied directory.

## Memory location

By default, memory and saved sessions live in:

```
~/.llm-orchestrator/memory/<project-hash>.md
~/.llm-orchestrator/memory/global.md
~/.llm-orchestrator/sessions/<project-hash>-<timestamp>.md
```

Override with `ORCH_HOME=/some/other/path`. The directories are created on first write.

## Verify

```
./scripts/install.sh --check
./tests/validate-skills.sh
```

Both should print OK.

## Profiles

```
export ORCH_HOOK_PROFILE=minimal    # bootstrap only, no memory load
export ORCH_HOOK_PROFILE=standard   # default — bootstrap + memory + guard
export ORCH_HOOK_PROFILE=strict     # all hooks active
```

Disable individual hooks without changing profile:

```
export ORCH_DISABLED_HOOKS=orch-guard
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
