---
name: requesting-code-review
description: Use when a finished change needs its Standard or Full review before it merges, becomes a PR, or is called done. Not for work in progress.
---

# Requesting code review

One script runs the whole review: `scripts/lib/orch-review.py`. It starts the
built-in reviewers (Claude Code's `/code-review` and `codex review`), proves
their findings, and decides the verdict from files it wrote. Start it once; no
step is yours to skip. The rules are in `docs/specs/review-design.md`.

## Which review

- **Standard:** one reviewer, from the provider that did not write the change
  when its CLI is installed (`codex review` on Claude Code, `/code-review` on
  Codex); otherwise your own, and the review says `same_provider`.
- **Full:** one `/code-review` and one `codex review`. With one CLI, its
  reviewer runs twice in separate copies and sessions, and the verdict line
  says both reviews came from one provider. A refuter then judges each
  serious or catastrophic finding.

Each reviewer is told to check the change against the spec and report any
other defect; the security lens (`references/security-lens.md`) is added when
the diff touches authentication, secrets, tokens or payments. Neither sees the
other's reply or your report.

A prover (`references/prover.md`) ranks each finding and writes a failing
command and fix, which the script runs; it cannot drop a finding. A defect, a
spec gap and a `codex review` priority 0 or 1 finding are at least serious.

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

- Repeat `wait`, with a tool timeout over 540 seconds, until it prints
  `"status": "finished"`.
- `"status": "crashed"` means no result: report the review as incomplete and
  start a new run in a new directory.
- The run directory must be new, outside the repository and outside every
  temporary directory (the sandboxes let reviewers write there).
- `--spec` is the file the change must implement. The review covers
  everything since the merge-base of `--base` and HEAD.
- Add `--allow-test-changes` when the task may change tests; otherwise a
  `test-tampering` finding is at least serious.

At least one of `claude` and `codex` must be installed and signed in; one that
is installed but signed out makes the review incomplete. With only Claude,
fixes run through a Claude runner instead of `codex sandbox`.

## The verdict

`review.json` in the run directory holds everything. `wait` prints the verdict
line, `same_provider`, the reasons for an incomplete review, the blocking ids,
each mild finding with its reason, and warnings (such as a kept `/code-review`
session it could not delete).

| Verdict | Meaning |
|---|---|
| `READY` | Every reviewer finished and nothing it reported survived. |
| `READY-WITH-FIXES` | Only mild findings. Fix them or record why not. |
| `NOT-READY` | At least one blocking finding (verified, unverified, promoted, unresolved or unjudged). |
| `INCOMPLETE` | Something is missing: a launch dropped out, a reply was not parsed, a serious finding had no repro, a finding went unjudged, or the checkout changed. Never report it as a pass. |

A finding never disappears: only a refuter drop the script proved with its
own run removes it from the verdict, and it stays listed. A failed reviewer is
never replaced. Report `INCOMPLETE` with its reasons, fix the cause, and run a
new review.

## After the review

Handle the findings with `receiving-code-review`. Then record what happened to
each one:

```bash
python3 "$REVIEW" record "$RUN_DIR" --dispositions <file>
```

Each finding gets one disposition (R21). `record` takes `refuted`, with a
`file-line` quote, never a test run, and rejects omissions.
