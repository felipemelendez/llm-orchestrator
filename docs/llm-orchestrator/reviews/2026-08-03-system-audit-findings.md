# System audit — findings

Date: 2026-08-03 · CLI at time of audit: Claude Code v2.1.220

> **STATUS UPDATE (2026-08-03, second pass).** Everything below has now been
> independently re-run rather than inherited, and the open items are closed.
> Corrections to this document's own claims, from direct execution:
>
> - **§2.2 "CI is red, stops at step 8 of 21"** — closed. Two causes, both test
>   bugs, neither in production code: `test-detect.sh` wrote `$TMP/…` and read
>   `/tmp/…` (green only on a machine with stale residue), and a
>   `test-protocol-hooks.sh` fixture used unescaped backticks inside a
>   double-quoted `python -c` string, so the shell ran them as command
>   substitution. A third, real, production defect surfaced only once CI could
>   reach the end: `_mtime` tried BSD `stat -f %m` first, but **GNU `stat -f`
>   succeeds and prints the mount point**, so the age arithmetic was a fatal
>   expansion error and the worktree engine was broken on Linux entirely.
>   CI now runs every step under `if: always()` and is green end to end.
> - **§3 "both aborts fail when the test suite rewrites a tracked file"** —
>   scope correction. They fail only when the rewritten file is one **the merge
>   itself touched**; a write to any other tracked file aborts cleanly.
>   Reproduced both ways.
> - **§2.3 "replacing `agents/orch-researcher.md` with a stub that inverts
>   every rule passes 42/42"** — **not reproducible.** A full inverting stub
>   fails 12 checks. The real defect is narrower and was confirmed exactly:
>   inverting the CONTRADICTED rule's *meaning* while leaving the vocabulary
>   intact passed all 42, because the assertion matched words, not polarity.
> - **§5.4 "`using-workflows` has no row in the controller routing table"** —
>   stale; the row is at `skills/using-orchestrator/SKILL.md:105`.
> - **§4's installer claims** — verified independently: 0 unrewritten
>   placeholders and 18/18 hook command paths absolute and existing after a
>   `--copy` install.
>
> Items found in this pass that were **not** in the original audit: a
> `guard-no-verify` regression introduced by the repair itself, three
> concurrency defects in the new lock code (an unbounded spin, a TTL branch
> that robbed live holders, and a release that deleted another process's
> lock), a denial-of-guard via unbounded brace expansion, and
> `git checkout -f -b` / `git branch -d -f` bypasses. See the commits on
> `fix/workflow-path-repair`.

Five parallel read-only audits covered the hook enforcement layer, the test suite, the shell
libs and worktree engine, the instruction layer, and packaging. Roughly 580 defects were
injected into production code one at a time and the covering test re-run.

**Every finding below is marked VERIFIED (reproduced directly, command output in-line) or
REPORTED (an auditor's executed evidence, not independently re-run). Treat REPORTED as a lead,
not a fact.** Several agent claims during this work turned out to be wrong on inspection.

---

## 1. Open — the enforcement layer does not enforce

### 1.1 Guard bypasses — VERIFIED

Both PreToolUse guards match option *spellings*, not semantics. Exit codes from the real hooks
(2 = block, 0 = allow):

```
reset hard (canonical)        2  BLOCK
reset hard (line-continue)    0  allow   <-- BYPASS
reset hard (abbrev --h)       0  allow   <-- BYPASS
clean fd (abbrev --for)       0  allow   <-- BYPASS
checkout -f (--no-pager)      0  allow   <-- BYPASS
checkout -f (-P)              0  allow   <-- BYPASS
branch -D (abbrev)            0  allow   <-- BYPASS
no-verify (abbrev)            0  allow   <-- BYPASS
FP: checkout -q -b            2  BLOCK   <-- FALSE POSITIVE
FP: switch --create           2  BLOCK   <-- FALSE POSITIVE
FP: checkout --help           2  BLOCK   <-- FALSE POSITIVE
```

Three distinct mechanisms:

- **Line continuation.** `orch-json.sh`'s newline-to-separator rewrite tracks quotes but not a
  preceding backslash, so a continuation becomes a command separator and adjacency never matches.
  A multi-line git command is the normal way to write a long one.
- **Long-option abbreviation.** Git accepts any unambiguous prefix. `--h` for `--hard`,
  `--no-verif` for `--no-verify`. An auditor confirmed `git commit --no-verif` committed past a
  failing pre-commit hook — the guard's sole purpose.
- **Valueless global options.** The checkout/switch rule is written as bare
  `git[[:space:]]+(checkout|switch)` with no flag absorber, and the normalizer strips only the
  five *value-taking* globals. `git --no-pager checkout -f main` walks past.

The false positives matter as much: a guard that blocks `--help` and legitimate branch creation
while allowing `--h` on a destructive reset is one a user disables.

Repro harness: `scratchpad/probe-guards.py` (feeds crafted PreToolUse payloads, reports exit
codes only — executes nothing destructive).

### 1.2 `ORCH_HOOK_PROFILE=strict` sets no strict flag — REPORTED

`ARCHITECTURE.md` states `strict` means "all hooks active *and* blocking". No script branches on
it to enable blocking; blocking comes only from the separate `ORCH_STRICT_*` knobs. Measured by
the auditor across protocol-grader, verify-gate and subagent-stop: `PROFILE=strict` allowed in
all three; the explicit flag blocked in all three.

### 1.3 The verify gate has a model-controlled kill switch — REPORTED

`orch-verify-gate.sh` matches the literal string `no verification needed (cosmetic)` as a
substring of the **raw** reply — inside a code fence, or in prose disclaiming it. The file claims
"the model is not in that loop. It cannot opt out."

### 1.4 The evidence gate's two checks are inert without `turn-start` — REPORTED

Both return silently when the turn-start marker is absent. Disabling the *cosmetic protocol
reminder* hook, or running dry-run, therefore removes anti-fabrication enforcement with no warning.

---

## 2. Open — the test suite is ~28% blind

**~165 of ~580 injected defects survived the test that claims to cover them.**

### 2.1 `validate-workflows.sh` Layer A has never been able to fail — VERIFIED

```
node --check on `function ( { {`
  without export:  rc=1   correctly rejected
  with export:     rc=0   SILENTLY ACCEPTED

$ cp broken.js workflows/ && bash tests/validate-workflows.sh
OK: 2 workflow script(s) validated
```

A file containing `export` is parsed as ESM, where `node --check` returns 0 on invalid syntax —
and the validator *requires* every workflow to begin with `export const meta`. The syntax check
has never rejected anything. Its `meta`-shape check is also a trailing-`*` glob that validates no
field: `export const metadata`, `meta = 42`, and a missing `name:` all pass.

**Consequence: `OK: N workflow script(s) validated` is not evidence of syntactic validity.**

### 2.2 CI is red and stops at step 8 of 21 — VERIFIED

```
failure  2026-08-03T18:03   failure  2026-08-03T17:52
failure  2026-08-03T01:36   failure  2026-08-03T01:36   failure  2026-08-03T01:36
```

`ci.yml` has no `if: always()` and no `continue-on-error`, so the 13 steps after `smoke.sh` have
not executed on any recent run — including `test-portability.sh` and `test-worktree-integrate.sh`
(56 checks) which `smoke.sh` does not invoke either. `smoke.sh` also discards captured output on
failure, so the log names the broken suite and nothing else.

One of the two failures is a test bug — VERIFIED:
```
tests/test-detect.sh:508   ... 2>"$TMP/lock-fallback-stderr.txt"
tests/test-detect.sh:509   FALLBACK_STDERR=$(cat /tmp/lock-fallback-stderr.txt)
```
Writes one path, reads another. Green on a machine with stale `/tmp` residue, red on a clean
runner.

### 2.3 Three systematic patterns behind the escape rate — REPORTED

- **Exit codes and substrings, not content.** Flipping `{"decision":"block"}` to
  `{"decision":"allow"}` in the verify gate leaves 37 checks green. Both `test-verify-gate.sh` and
  `test-retry-cap.sh` assert only `rc == 2` and discard stdout.
- **Greps against markdown standing in for behaviour.** `test-research-brief.sh` is 42/42 static
  greps; replacing `agents/orch-researcher.md` with a stub that *inverts every rule* passes 42/42,
  because assertions like `grep -qE 'first-class|halts the workflow'` are polarity-blind.
- **Tests that reimplement production logic and test the copy.** `smoke.sh` defines its own
  `classify()` duplicating `commands/remember.md`; the two have already drifted.

### 2.4 Six suites turn a missing dependency into a pass — REPORTED

`test-evidence-ledger.sh`, `test-guard-no-verify.sh`, `test-hook-latency.sh`,
`test-verify-gate.sh`, `test-retry-cap.sh`, `test-worktree-reaper.sh` all print
`PASS: <name> (skipped — python3 unavailable)` and exit 0; `smoke.sh` greps the `PASS:` prefix.
No-python3 is precisely the environment where `orch-json.sh` degrades and the guards are weakest.

`smoke.sh` itself gets this right (`skipped()` helper with its own counter) — the six siblings do
the opposite.

### 2.5 Named coverage gaps — REPORTED

Each is a mutation that survives the suite claiming to cover it:
- `orch-researcher-validator.sh` — delete the `agent_type` read and both suites stay green; all
  four test invocations send `subagent_type`, and `grep -c '"agent_type"' tests/test-research-gate.sh` is 0.
- `orch-evidence-ledger.sh` — force `exit_code = 0`; a verify command that **failed** becomes
  green evidence and the completion claim ships. `PostToolUseFailure` appears in `tests/` only in a comment.
- `guard-destructive-git.sh` — add a JSON-parse fail-open; 130 checks stay green. There is no
  malformed-payload test for this guard.
- `guard-destructive-git.sh` — drop the `gitdir:` content check; a forged `.git` file plus an
  `.orch-active` marker lets `git reset --hard HEAD~2` through on the shared checkout.
- `guard-no-verify.sh` — delete the `-n` short-flag arm (three independent paths); the suite has
  no `-n` case at all, despite the file header calling it "the two-character bypass that shipped
  broken for the whole life of this guard".
- `orch-worktree-reaper.sh` — drop the agent-id match; the reaper releases a live sibling's mutex.
- `orch-verify-gate.sh` — drop the heading/bold prefix from the `Changed:` regex; `**Changed:**`
  with no `Verify:` passes silently.
- `test-hook-latency.sh` — breaking a hook outright still passes; it discards exit code and output.
- `test-portability.sh` — its `scan()` reads only `scripts/` and `hooks/`, so GNU-only constructs
  in `tests/`, `commands/` and `agents/` are invisible; its own exclusion filters are dead code.
- `validate-skills.sh` — deleting seven skill directories still exits 0; the counts are real but
  compared to nothing. A `SKILL.md` with no frontmatter at all passes.

---

## 3. Open — libs and the worktree engine

All REPORTED unless marked.

- **`rollback_all` can destroy another session's live worktree.** `git worktree remove --force`
  fires on paths recorded by the current run; under a claim/create race the auditor observed it
  removing a populated worktree another session owned, leaving an orphaned branch and an empty
  registry. The winning session exited 0 and printed a path that no longer existed. This is the
  one place uncommitted work can be lost without a second command.
- **`orch-worktree-integrate.sh` reports "the merge was discarded and the base is unchanged"
  while leaving the base mid-merge.** Both aborts fail when the test suite rewrites a tracked file
  — which the script's own comment calls "the NORMAL case" — and `|| true` swallows it. The next
  run then advises committing the red merge.
- **A SIGKILLed lock holder strands the lock permanently.** No trap, no TTL, no PID check. The
  Stop-hook prune claims to clear stranded locks but uses `find -type f -delete`, which cannot
  remove a directory — **VERIFIED**. Two callers respond to lock timeout by writing *unlocked*, so
  one killed process makes the lock a permanent no-op for those files.
- **Every worktree of a repo shares one unlocked regression baseline.** A parallel writer writing
  a red baseline makes `orch_regression_check` skip the guard and return 0 for its siblings.
- **`orch_regression_check` returns "no regression" when the test command disappears.** A green
  baseline proves one existed; its absence is the signal, reported as clean. `return 2` (unknown)
  exists and is not used here.
- **Duplicate-slug guard is dead code.** `sanitize()` uses `printf '%s'` with no newline, so
  `... | sort | uniq -d` sees one concatenated line. A different guard happens to fire, which is
  why the test named for it passes.
- **`ORCH_SIG_SECURITY_DIFF` misses most of its stated vocabulary.** Measured misses on realistic
  hunks: `api_key`, `hmac`, `BEGIN RSA PRIVATE KEY`, `httpOnly`, `Access-Control-Allow-Origin`,
  `nonce`, `randomBytes`, `saml`, `/login`, `hasPermission`, `innerHTML`, `eval(req.body.code)`,
  and the entire payments vocabulary except the literal word "payment" — `stripe.charges.create`,
  `refundOrder`, `billing` all miss. The file says Stage 3 "should fail toward running".
- **`ORCH_SIG_LIBRARY_STRUCTURAL`** has `npm(\s+(i|install))?` with the subcommand optional, so
  "Refactor the npm scripts" falsely compels research.

---

## 4. Fixed in this branch (uncommitted)

Each was verified by direct execution after the fix.

| Defect | Evidence of fix |
|---|---|
| `install.sh --copy` never rewrote hook paths (brace-blind sed) and printed success anyway; **every `--copy` install had a dead enforcement layer**. The guarding smoke check was brace-blind in the same way | `unrewritten placeholders: 0` (was 18); `command paths absolute+existing: 18/18` (was 0/18). The installer now verifies before claiming, and exits 1 on failure |
| `workflows/` was never copied by `--copy`, so installed skills referenced a missing file while `--check` reported healthy | `tests/test-workflow-distribution.sh` → `OK: workflow distribution` |
| `review-diff.js` reported reviews COMPLETE and CLEAN across four distinct paths: a dead spec gate, a dead stage-2/3 reviewer, a thrown skeptic, and a skeptic returning null. Refuted findings vanished with no record | 72/72 mutations killed (was 12/30). Return now carries `refuted` (with the reason each blocker was deleted), `unverifiedFindings`, `droppedFindings`, `coercedSeverities` |
| Three skills sourced leaf libs standalone; `orch_regression_check` returned nonzero unconditionally with a fabricated reason, while `finishing-a-branch` says to refuse the merge on nonzero | Call sites now source `orch-detect.sh`; the gate distinguishes rc=1 (real regression) from rc=2 (no baseline) |
| `config/profiles.json` documented 8 of 16 hooks and claimed `minimal` disables guards that have no profile gate | Deleted — nothing read it, and a wrong map is worse than none |
| `--check` never resolved a single `command` path from `hooks.json`; corrupt JSON and deleted hook scripts both reported OK | Now parses the manifests and resolves every command path |
| `test-lib-resolution.sh` (5 checks) and `test-worktree-materialize.sh` (37) ran in no automated context | Wired into `ci.yml` |

---

## 5. Environmental gotchas

- **`grep` is shadowed by a gitignore-aware shell function.** A bare recursive `grep -r` silently
  skips `docs/llm-orchestrator/{specs,plans,handoffs,research}/` — every research brief, spec, plan
  and handoff. Verify with `type grep`; use `command grep -r`, or name the directory explicitly.
  This produced at least one confidently wrong "not found" during this work.
- **`scripts/hooks/guard-destructive-git.sh` blocks destructive git**, including branch switches
  on the main checkout. An inline `ORCH_ALLOW_DESTRUCTIVE_GIT=1` prefix does **not** disarm it —
  the variable must be in the hook's own process environment.
- **macOS bash 3.2**: no `${var@Q}`, no `mapfile`, no associative arrays, no `grep -P`.
