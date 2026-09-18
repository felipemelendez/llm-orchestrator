# LLM Orchestrator in Codex — this repository

This checkout is the framework itself. Codex sessions here run under the same
proportional cadence the plugin ships; read `AGENTS.md` and `LAWS.md` first.

## Hooks and trust

The global installer (`scripts/install.sh --codex`) registers the cadence file
guard, the evidence hook and the task-cleanup hook in `~/.codex/hooks.json`,
pointing at this checkout. Changed hook definitions execute only after the
person reviews them with `/hooks` in a fresh Codex session; installation is
not trust. The copied skill lives at `~/.agents/skills/cadence`; refresh it with
the installer after any change under `skills/cadence/`.

The file guard refuses commands and patches that name `LAWS.md`,
`cadence.json`, `LOCK.sha256`, `orch-cadence-check.sh`, `.claude/settings.json`
or `.githooks/commit-msg` unless they are one plain read. Read those files with
one `cat` and nothing else on the line.

## Checks and evidence

Ordinary Codex shell output carries no exit status or working directory, so
run every check through the trusted runner with fresh absolute private paths:

```sh
python3 /Users/felipemelendez/LLM-Orchestrator-cadence/scripts/verification/codex-verify.py --cwd /Users/felipemelendez/LLM-Orchestrator-cadence --receipt /ABSOLUTE/FRESH/receipt.json --output /ABSOLUTE/FRESH/output.log -- bash tests/test-cadence-docs.sh
```

Recognized checks are `bash tests/test-<name>.sh` and
`python3 tests/test-<name>.py` from this root, one direct command after `--`.
Run the legacy gate and ledger suites through
`python3 tests/test-proportional-install.py`; the bare ledger suite prints a
fixture label the recognizer treats as an empty result. Pass, empty, failed,
interrupted and stale results are recorded as they are; a later unrelated
green cannot erase a failure. End with `Verification: PASS | PENDING |
BLOCKED | NOT APPLICABLE — reason`.

Receipts and logs belong in task-owned scratch from
`skills/cadence/scripts/orch-task-resources.py`; acquire a lease before use and
finish the task after consumers stop. See `docs/codex-evidence.md` for the full
recognition and storage contract and `docs/install.md` for installation.
