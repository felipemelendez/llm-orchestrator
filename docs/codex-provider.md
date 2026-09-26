# Reviews from Codex

On Codex, the `requesting-code-review` skill runs the same script as on Claude
Code, with `--writer codex`:

```sh
python3 /path/to/LLM-Orchestrator/scripts/lib/orch-review.py run --detach \
  --path standard|full --writer codex --base <ref> --spec <file> \
  --run-dir <new directory outside the repository>
python3 /path/to/LLM-Orchestrator/scripts/lib/orch-review.py wait <run-dir> --seconds 540
```

Repeat `wait` until it reports that the run finished. The rules are in
`docs/specs/review-design.md`.

## Which provider runs which seat

- **Standard** runs one contract seat on Codex (`codex exec`).
- **Full** runs the contract seat on Codex and the adversarial seat on Claude
  (`claude -p`), because the adversarial seat runs on the provider that did not
  write the change. The refuter is always Claude.

Full therefore needs both CLIs installed and signed in (`codex login status`,
`claude auth status --json`). If either is missing, the review is
`INCOMPLETE`. A missing provider is never replaced by another provider, model
or brief.

## Models and effort

- Claude seats run `--model opus --effort high`. The served model is read from
  the assistant messages and must be an Opus model.
- Codex seats pass no `-m`: they use the `model` in `$CODEX_HOME/config.toml`
  (`~/.codex` by default) at `model_reasoning_effort="high"`. The served model
  and effort are read from the session rollout file. If `config.toml` names no
  model, the served model is recorded but not compared.

`review.json` records the requested and served model and effort of every
launch.

## Where the seats run

Each seat runs in its own disposable clone of the repository with the change.
The Codex seat runs with `-s workspace-write`, so it can write inside its
clone. The Claude seat runs with no MCP servers and only the Read, Grep, Glob
and Bash tools; its Bash is not confined to the clone, so the script compares
a fingerprint of the real checkout before and after, and a change gives
`INCOMPLETE`.

Proposed fixes are run by the script itself under
`codex sandbox -P :workspace -C <copy> --`, which allows writes only in the copy
and the system temporary directory and blocks network access. This was checked
on macOS; on Linux Codex uses a different sandbox, and if it cannot start, the
finding is left unreproduced and stays blocking.

## Signing in from a Codex sandbox

A Codex sandbox can stop `claude` from reading the operating system credential
store even when a normal terminal reports a valid login. Then run the review
through the normal Codex approval path; do not ask for a secret or a new
subscription.

## Tests

```sh
python3 tests/test-review.py
```

The tests use fake `claude` and `codex` programs and make no model calls.
