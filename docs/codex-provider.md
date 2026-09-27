# Running a review by hand

Normally you just ask the assistant for a review (in Claude Code,
`/llm-orchestrator:review`); it runs everything below for you, on Claude Code
or Codex. This page is for running the review script yourself and reading
its result.

## Run a review

Find the script, then start a review of the current change:

```sh
REVIEW=$(find ~/.claude/plugins ~/.codex/plugins/cache -name orch-review.py -path '*llm-orchestrator*' 2>/dev/null | tail -1)
python3 "$REVIEW" run --detach --path standard --writer codex \
  --base origin/main --spec <file the change must implement> \
  --run-dir <a new folder outside the repository>
python3 "$REVIEW" wait <that folder> --seconds 540
```

- `--path full` asks for a Full review instead of Standard.
- `--writer` is the tool that wrote the change: `codex` or `claude`.
- Repeat `wait` until it reports that the run finished.

The result is `review.json` in the run folder. Nothing is saved in the
repository.

## What the verdict means

| Verdict | Meaning | What to do |
|---|---|---|
| `READY` | Every reviewer finished and nothing it reported held up. | Go ahead. |
| `READY-WITH-FIXES` | Only mild findings. | Fix each one or note why not. |
| `NOT-READY` | At least one serious finding blocks. | Fix it, or show with evidence that it is wrong, then run a new review. |
| `INCOMPLETE` | Something is missing: a reviewer dropped out or is not signed in, a reply could not be read, or the checkout changed during the run. | Never treat it as a pass. Fix the cause and run a new review. |

After handling the findings, the assistant records what happened to each with
`orch-review.py record`.

## Who reviews

The reviewers are the built-in ones: Claude Code's `/code-review` and
`codex review`.

- **Standard** runs one review, from the other tool when it is installed: a
  change Codex wrote is reviewed by `/code-review`, and one Claude Code wrote
  by `codex review`. With only one tool installed, it reviews its own work, and
  the result is marked `same_provider` (both sides came from the same tool).
- **Full** runs both. With only one tool installed, that tool reviews twice,
  each time in its own copy, marked `same_provider`.

Two more steps check the findings. The **prover** ranks each finding and
writes a command that shows the failure and a proposed fix; the script runs
them in a sandbox. On Full, the **refuter** can drop a serious finding only if
a check the script runs shows it is wrong. Both run on Claude when it is
installed, else on Codex. A reviewer that is missing or fails is never
replaced by another tool or model.

How the script checks each step: [ARCHITECTURE.md, Layer 6](../ARCHITECTURE.md#layer-6--code-review-by-one-script).

## Signing in from a Codex sandbox

A Codex sandbox can stop `claude` from reading the system's credential store,
even when a normal terminal shows a valid login; the review is then
`INCOMPLETE`. Run the review through Codex's normal approval path instead; do
not ask for a secret or a new subscription.
