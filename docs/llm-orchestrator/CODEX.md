# LLM Orchestrator in Codex — this repository

This checkout is the framework itself. Codex sessions here run under the same
proportional cadence the plugin ships; read `AGENTS.md` and `LAWS.md` first.

## Hooks and trust

The Codex plugin (`.codex-plugin/plugin.json`, installed with
`codex plugin marketplace add <this checkout>` and
`codex plugin add llm-orchestrator@llm-orchestrator`) registers the cadence
skill and two hooks: the file guard (`codex-cadence-adapter.sh`, PreToolUse)
and the completion check (`codex-verify-gate.sh`, Stop), plus the
task-scratch cleanup on Stop. `scripts/install.sh --codex` adds only the
instructions block to `~/.codex/AGENTS.md`. Codex runs the plugin from its
copy under `~/.codex/plugins/cache/`; run `codex plugin add` again after any
change to the skill or the hooks. A changed hook definition runs only after
the person reviews it with `/hooks` in a fresh Codex session; installation is
not trust.

The file guard refuses commands and patches that name `LAWS.md`,
`cadence.json`, `LOCK.sha256`, `orch-cadence-check.sh`, `.claude/settings.json`
or `.githooks/commit-msg` unless they are one plain read. Read those files with
one `cat` and nothing else on the line.

## Checks

Run each suite as one plain foreground command from this root:
`bash tests/test-<name>.sh` or `python3 tests/test-<name>.py`, or the whole
suite with `bash tests/run-all.sh`. End with
`Verification: PASS | PENDING | BLOCKED | NOT APPLICABLE — reason`. If a reply
says PASS and Codex's own record shows no such command finishing with exit 0
in the turn, the completion check sends the agent back once with a note; it
prints nothing for the person and never rejects the turn. See `docs/codex.md`.

Temporary reviews and copies belong in task-owned scratch from
`skills/cadence/scripts/orch-task-resources.py`; finish the task after
consumers stop.
