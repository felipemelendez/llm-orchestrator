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

## Which reviewer runs

The reviewers are the built-in ones: Claude Code's `/code-review` and
`codex review`.

- **Standard** runs `/code-review` when `claude` is installed, because the
  review should come from the provider that did not write the change. Without
  `claude` it runs `codex review` and records `same_provider`.
- **Full** runs one `/code-review` and one `codex review`. With only `codex`
  installed it runs `codex review` twice, each in its own copy, and the verdict
  line says both reviews came from one provider.
- The prover and the refuter run on Claude when it is installed, else on Codex
  (`codex exec`).

A CLI that is installed but not signed in (`codex login status`,
`claude auth status --json`) makes the review `INCOMPLETE`. A missing or failed
reviewer is never replaced by another provider or model.

## What the script checks

- `/code-review` runs `--model opus --effort high --safe-mode --restricted`
  with no MCP servers and Claude Code's Bash sandbox. Its tool calls are in the
  session transcript, which the script reads (the sandbox settings and a probe
  that must show a refused write) and then deletes by its exact session id.
  Every model in the result's `modelUsage` must be an Opus model.
- `codex review --uncommitted` runs read-only with MCP servers, apps and
  plugins off, and the spec instruction as `developer_instructions`. The script
  finds the review's rollout under `$CODEX_HOME/sessions` and checks the served
  model (against `config.toml`'s `model`, when set), effort `high`, the
  `read-only` sandbox, and that no MCP tool ran.

`review.json` records the requested and served model and effort of every
launch, and the served sandbox or probe result.

## Where the work runs

Each reviewer, prover and refuter runs in its own disposable clone whose HEAD
is the merge-base, so the whole change is uncommitted there. The script
compares a fingerprint of the real checkout before and after, and a change
gives `INCOMPLETE`.

Proposed fixes are run by the script itself under
`codex sandbox -P :workspace -C <copy> --`, which allows writes only in the copy
and the system temporary directory and blocks network access. This was checked
on macOS; on Linux Codex uses a different sandbox, and if it cannot start, the
finding is left unreproduced and stays blocking. Without `codex`, a sandboxed
Claude runner runs them instead.

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
