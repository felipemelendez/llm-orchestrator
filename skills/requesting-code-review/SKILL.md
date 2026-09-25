---
name: requesting-code-review
description: Use when a finished change needs its Standard or Full review before it merges, becomes a PR, or is called done. Not for work in progress.
---

# Requesting code review

One script runs the whole review: `scripts/lib/orch-review.py`. It starts the
reviewers itself, checks their evidence, runs their proposed fixes, and decides
the verdict last, from files it wrote. Start it once and read its result; no
step is yours to run or skip. The rules are in `docs/specs/review-design.md`.

## Which review

- **Standard:** one reviewer with the contract brief, on your own provider.
- **Full:** a contract reviewer and an adversarial reviewer on two providers.
  The adversarial one runs on the provider that did not write the change (GPT
  through Codex when you are Claude Code, Claude when you are Codex). When any
  finding is serious or catastrophic, a Claude refuter then judges each one.

Neither reviewer sees the other's findings or your report. Each works in its
own disposable clone of the repository with the change, and can run the tests.
When the diff touches authentication, secrets, tokens or payments, both briefs
get the security lens (`references/security-lens.md`).

## Running it

Find the script, then start the run in the background (R1). Set `--writer` to
your harness (R2): `claude` on Claude Code, `codex` on Codex.

```bash
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
REVIEW=$(orch_lib orch-review.py)
RUN_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/reviews/$(date +%Y%m%d-%H%M%S)"
python3 "$REVIEW" run --detach --path full --writer claude --base origin/main --spec <spec file> --run-dir "$RUN_DIR"
python3 "$REVIEW" wait "$RUN_DIR" --seconds 540
```

- Repeat `wait` until it prints `"status": "finished"`. Give each `wait` a
  tool timeout longer than 540 seconds. `"status": "running"` means call it
  again.
- `"status": "crashed"` means the run stopped without a result. Report the
  review as incomplete, and start a new run in a new directory. `run` refuses
  a directory that already exists.
- The run directory must be new, outside the repository and outside every
  temporary directory (the sandboxes let reviewers write there). The script
  writes nothing inside the repository.
- `--spec` is the file the change must implement. `--base` is the ref the
  change is reviewed against.
- Add `--allow-test-changes` when the task may change tests; otherwise a
  `test-tampering` finding is raised to serious.
- `--brief`, `--adversarial-provider`, `--split` and `--no-refuter` exist only
  for measurement (T10). Do not use them for a real review.

Full needs `claude` and `codex` both installed and signed in. Standard needs
your own provider; without `codex`, fixes cannot be run, so a serious finding
stays unverified.

## The verdict

`review.json` in the run directory holds everything. `wait` prints the verdict,
the reasons for an incomplete one, and the ids of blocking and mild findings.

| Verdict | Meaning |
|---|---|
| `READY` | Every reviewer finished, checked everything, and found nothing. |
| `READY-WITH-FIXES` | Only mild findings. Fix them or record why not. |
| `NOT-READY` | At least one blocking finding (verified, unverified, promoted, unresolved or unjudged). |
| `INCOMPLETE` | Something is missing: a reviewer dropped out, an item was not checked, a serious finding had no repro, the refuter did not judge a finding, or the checkout changed during the review. Never report it as a pass. |

A missing or failed reviewer is never replaced by another provider or model.
Report `INCOMPLETE` with its reasons, fix the cause, and run a new review.

## After the review

Handle the findings with `receiving-code-review`. Then record what happened to
each one:

```bash
python3 "$REVIEW" record "$RUN_DIR" --dispositions <file>
```

The file gives every finding id one disposition (R21): `fixed`, with the check
that failed before and passes after; `refuted`, with a `file-line` quote that
`record` checks against the reviewed files (a test run is not accepted); or
`ignored`, with a reason. `record` rejects a file that leaves any finding out.

## The native `/code-review`

Claude Code's own `/code-review` is a separate check. The person or the agent
may run it (the agent can invoke it unless the person set
`skillOverrides: {"code-review": "user-invocable-only"}`), but it does not
count as this review. T10 compares the two.
