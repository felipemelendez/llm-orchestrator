# Install

Three ways to get LLM Orchestrator running.

## Option 1 — Claude Code plugin

```
/plugin marketplace add https://github.com/<your-org>/llm-orchestrator
/plugin install llm-orchestrator
```

After install, restart the session. The SessionStart hook will inject the `using-orchestrator` meta-skill, the latest saved session for this project, and any project memory.

Verify:

```
/plugin list
```

## Option 2 — Symlink into your home dir

Clone, then:

```
cd /path/to/llm-orchestrator
./scripts/install.sh --link
```

This creates `~/.claude/llm-orchestrator -> /path/to/llm-orchestrator`. To make Claude Code load it, use the marketplace flow:

```
/plugin marketplace add ~/.claude/llm-orchestrator
/plugin install llm-orchestrator
```

The symlink keeps the install in sync with your local checkout — `git pull` in the original directory updates the plugin in place.

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
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/user-prompt-submit.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/guard-no-verify.sh" }] }
    ],
    "SubagentStop": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/subagent-stop.sh" }] }
    ],
    "Stop": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "bash /full/path/to/.claude/scripts/hooks/orch-stop.sh" }] }
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

Other knobs:

```
export ORCH_HOME=/some/path             # where plugin memory + research cache live
export ORCH_SESSION_MAX_CHARS=12000     # cap injected context at SessionStart (default 8000)
export ORCH_STRICT_RESEARCH=1           # escalate researcher fidelity warnings to blocks (exit 2)
export ORCH_ALLOW_NO_VERIFY=1           # let `--no-verify` flags through
```

## Cross-harness

Claude Code is supported first-class. Codex / Gemini / Copilot mirrors are on the v0.3 roadmap. For now you can copy `skills/`, `commands/`, `templates/` into the harness's config directory by hand and wire the session-start equivalent to `scripts/hooks/session-start.sh`.
