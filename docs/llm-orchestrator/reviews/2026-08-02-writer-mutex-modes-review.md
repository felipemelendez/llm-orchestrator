# Review — explicit writer-isolation modes (2026-08-02)

Diff: staged working tree on `fix/hook-correctness-and-tdd-parity` (12 files, +260/−23).
Stages run: 1 (spec, orch-spec-reviewer) and 2 (quality, orch-code-reviewer). Stage 3 skipped — security grep (`$ORCH_SIG_SECURITY_DIFF`) did not match.

## Verdicts

- Stage 1: with-fixes — all spec items A–E implemented as written; worktree mutex not weakened.
- Stage 2: with-fixes — shell sound (never deletes, never blocks, exits 0, Bash-3.2 clean); two Importants.

## Findings and dispositions

| Sev | Finding | Disposition |
|---|---|---|
| Important | test python3 guard mid-file `exit 0` could print PASS over failed checks | fixed — `finish()` summarizes honestly at both exits; verified: python3-less green → exit 0 with skip note; python3-less + planted regression → exit 1 |
| Important | solo main-checkout envelope fell into the fail-closed bullet | fixed — explicit "Solo main checkout" mode in agents/orch-implementer.md and templates/implementer-prompt.md |
| Important | shared-checkout writers not told they own no git operations | fixed — clause in both writer surfaces |
| Important | dangling symlink at mutex path invisible to reaper and blocks forever | fixed — `is_corrupt()` treats any non-directory (symlinks included) as corruption; new test check |
| Minor | reaper double-reports a corrupted path named in the mutex map | fixed — `CORRUPT_SEEN` dedupe |
| Minor | "is a regular file" message inaccurate for fifo/symlink | fixed — "(or other non-directory)" |
| Minor | corruption scan rooted at CWD missed repo root when CWD inside a worktree | fixed — `BASE` strips `/.worktrees/...` |
| Minor | E(3) assertion positive-only | fixed — added `! grep 'still held'` check |
| Minor | declaration-without-file-list was fail-open | fixed — invalid declaration → fail closed, both surfaces |
| Minor | README:215 contradicted the new third shape | fixed |
| Minor | CHANGELOG "as before" understated the fail-closed scope widening | fixed |
| Minor | dispatching-subagents at 244/250 lines | parked — real, not load-bearing; next addition should displace something |
| Minor | LEFT joins paths with trailing space (display-only) | parked — contested — ruling: cosmetic, `ls`-parse removal is already an improvement |

## Round 2 — review-diff workflow (adversarial, wf_4eb44b52-f32)

3 agents on claude-opus-5[1m]: spec gate → quality → executing skeptic. Caveat: the harness
stringified `args`, so reviewers received empty spec/diff slots and recovered by reading
`git diff --cached` directly — findings are grounded in the real staged diff.

| Sev | Finding | Disposition |
|---|---|---|
| Important (CONFIRMED, executed) | corruption scan anchored at payload cwd — silent from a subdirectory of the checkout | fixed — BASE via `git rev-parse --show-toplevel` with cwd fallback; scan moved before all reap-and-exit paths; subdir + early-exit test checks added |
| Important (0.7) | commands/dispatch.md still mandated worktrees before any parallel batch — shared mode unreachable | fixed + pinned (MODE_DECL grep on dispatch.md) |
| Important (0.65) | "main checkout" literal drift: skill said bare string, template defines the exact line — sequential dispatches could fail closed | fixed + cross-pinned in test |
| Important (0.55) | ARCHITECTURE implied the two backstops cover shape 3 | fixed — asymmetry stated in ARCHITECTURE.md:51 and the shared-checkout steps intro |
| Minor | using-workflows stale cross-reference; README "Safe parallel work" contradiction; tests/README missing suite row; unquoted `rm %s` in reaper message; space-poisoned CORRUPT_SEEN dedupe; comment-only 'worktree-mode-only' grep | all fixed (grep repointed at validator behavior: maxTurns fixture → exit 1) |
| Minor (0.5) | drop ~8 single-file prose pins | parked — contested — ruling: pins also catch accidental deletion in future edits at ~zero cost; repo idiom (validate-skills) tolerates prose pins |

## Post-fix verification

- `tests/test-writer-mutex-modes.sh` → PASS (29 checks)
- `tests/test-worktree-reaper.sh` → PASS (10 checks)
- `tests/validate-skills.sh` → OK: 18 skills, 14 commands, 7 agents
- `tests/smoke.sh --quiet` → All 72 checks passed.
