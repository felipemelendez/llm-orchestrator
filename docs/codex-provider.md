# Reviews from Codex

On Codex, the `requesting-code-review` skill runs the same review script as on
Claude Code, `scripts/lib/orch-review.py`, with `--writer codex`. This page
says how to run it and which reviewer it uses. How the script checks and
decides is in [ARCHITECTURE.md, Layer 6](../ARCHITECTURE.md#layer-6--code-review-by-one-script).

## Run a review

```sh
python3 <plugin>/scripts/lib/orch-review.py run --detach \
  --path standard --writer codex --base <ref> --spec <file> \
  --run-dir <new folder outside the repository>
python3 <plugin>/scripts/lib/orch-review.py wait <run-dir> --seconds 540
```

Use `--path full` for a Full review. Repeat `wait` until it reports that the
run finished. The result is `<run-dir>/review.json`, with a verdict of
`READY`, `READY-WITH-FIXES`, `NOT-READY` or `INCOMPLETE`. Nothing is saved in
the repository.

## Which reviewer runs

The reviewers are the built-in ones: Claude Code's `/code-review` and
`codex review`.

- **Standard** runs one review from the other provider, so a change Codex
  wrote is reviewed by `/code-review` when `claude` is installed. Without
  `claude`, it runs `codex review` and records `same_provider`.
- **Full** runs one `/code-review` and one `codex review`. With only `codex`
  installed it runs `codex review` twice, each in its own copy, and the verdict
  says both came from one provider.
- The prover and the refuter run on Claude when it is installed, else on Codex.

A CLI that is installed but not signed in (`codex login status`,
`claude auth status --json`) makes the review `INCOMPLETE`. A missing or failed
reviewer is never replaced by another provider or model.

Proposed fixes are tested by the script in `codex sandbox`, which allows writes
only in a throwaway copy and blocks network access. This was checked on macOS;
on Linux Codex uses a different sandbox, and if it cannot start, the finding
stays unproven and blocking. Without `codex`, a sandboxed Claude runner is used
instead.

## Signing in from a Codex sandbox

A Codex sandbox can stop `claude` from reading the system's credential store,
even when a normal terminal shows a valid login. If so, run the review through
Codex's normal approval path; do not ask for a secret or a new subscription.
