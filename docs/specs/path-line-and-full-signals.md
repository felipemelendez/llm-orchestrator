# A risk line per task, the signals that force Full, and security findings that are never deferred quietly

Date: 2026-10-15
Status: approved (Felipe's mandate of 2026-10-15; the controller filled in the design)

## Problem

- A plan says what each task does and when it is done, but not how much
  process it needs. The path (Simple, Standard, Full) is chosen once for the
  whole ticket, if at all, and a one-line permission change inside a
  "simple" ticket gets no review.
- The cadence skill says Full is for "interacting architecture, difficult
  recovery, substantial uncertainty or consequential contracts". Those words
  do not tell an agent which concrete things force Full, so unknown risk gets
  averaged down to Standard.
- Landing rule 7 and R23 let an unreproduced serious finding be recorded
  `follow-up` and the branch lands. A failed reproduction does not disprove a
  security, privacy or data-integrity concern, yet the record accepts the
  deferral with no one asked.

## Goals

- `templates/plan.md` carries one `Path:` line per task, in the form
  `Path: Simple | Standard | Full — <one sentence: why, naming the signal>`,
  with a one-line explanation in the task block.
- `skills/writing-plans/SKILL.md` says every task carries the line, that the
  choice follows the cadence skill's three questions (impact, uncertainty,
  reversibility) and its Full signals, and that "unknown" is never Simple.
- `skills/dispatching-subagents/SKILL.md` and
  `skills/dispatching-parallel-agents/SKILL.md` say the envelope pastes the
  task's `Path:` line with the task text, a Full task gets a per-task review,
  the controller reassesses the path when scope grows or a round finds
  something consequential, and a reviewer may raise it.
- `skills/cadence/SKILL.md` lists, in plain words, the signals that force
  Full, and `skills/cadence/CADENCE.md`'s Full path mirrors the list:
  permissions, identity, privacy, or data whose loss is hard to undo; effects
  that cannot be reversed or recovery that is hard; concurrency, shared state,
  retries with side effects, ordering; contracts between components or
  repositories whose failure breaks the whole; invariants not obvious from
  the code; unknown risk counts as high, one signal is enough, never averaged
  away, so a one-line permission change can need Full while a large
  mechanical change is Simple.
- `orch-review.py record` accepts `follow-up` for a finding on a review that
  ran with the security lens, or whose kind or words name security, privacy
  or data integrity, only with `"person_approved": true`, the same key
  `ignored` uses. Every other part of R23 and rule 7 stays.
- Tests assert the template line, the two skills' mention of it, the cadence
  skill's signals, and the record rule; `bash tests/validate-skills.sh`,
  `bash tests/test-protocol-drift.sh`, `bash tests/test-cadence-docs.sh`,
  `bash tests/test-landing-rules.sh` and `bash tests/test-review.sh` pass.

## Non-goals

- No change to `templates/cadence-global-block.md` or
  `skills/cadence/references/global-block.md`: they are locked content in
  cadence projects and change only by ruling.
- No change to the verdict, to what blocks, or to `refuted`, `settled`,
  `fixed` and `ignored`. Nothing else from the Mia playbook enters the
  plugin.
- No new field in the plan beyond `Path:`; no new envelope slot unless the
  task block cannot carry the line (it can: the task text is pasted whole).
- No word ceiling in `tests/validate-skills.sh` is raised; text is shortened
  elsewhere in the same skill.

## Approach

- **Plan template.** `Path:` sits after `Owner:` in each task block, so the
  envelope's pasted task text already carries it. One explanatory line in
  the first task block, in the template's own voice. The implementer prompt's
  task slot says the pasted task includes its `Path:` line; no new slot.
- **Skills.** One short paragraph in `writing-plans` under the termination
  contract. One sentence in each dispatch skill where the envelope is built
  (step 1 of the sequential skill; step 3 of the isolated-writers steps in the
  parallel skill), and one where review is chosen (step 3 of the sequential
  skill; step 6 of the parallel skill). Reassessment and a reviewer's raise go
  in the same sentence.
- **Cadence.** The signals go in one short list directly under the paths
  table in `skills/cadence/SKILL.md`; the skill is at its word ceiling, so
  the lines on reusing checks and the finish section are tightened by the
  same number of words. `CADENCE.md` names the same signals in step 1 of the
  Full path.
- **Record.** `review.json` gains `"security": true|false`, copied from the
  start fingerprint the preflight already writes (the diff matched
  `ORCH_SIG_SECURITY_DIFF`). In `record`, a `follow-up` entry for a finding
  on a security-lens review, or whose `kind` or `words` match
  `security|privacy|data[-_ ]integrity`, is a problem unless
  `person_approved` is `true`; the message says a failed reproduction does
  not disprove such a concern and names the key. Older runs without the field
  read as `false`. The problem is added after the existing follow-up checks,
  so a reproduced or never-run finding keeps its existing message.
- **Error handling.** `record` already collects every problem and prints
  them together; the new check joins that list. No new exit code.
- **Testing.** One test in `tests/test-review.py`: a security diff
  (`auth.py` with a password, as the R4 test does) and one unverified serious
  finding whose repro passed; `follow-up` without the key is refused with the
  new message; with `"person_approved": true` it is recorded and the outcome
  row says `follow-up`; a second sub-case on an ordinary diff whose finding
  words say "privacy" is refused the same way; `review.json` carries
  `security`. The shell suites gain `grep` assertions for the `Path:` line
  (`test-landing-rules.sh`, which already checks the plan template) and the
  Full signals (`test-cadence-docs.sh`). Existing assertions are kept.
- **Alternatives rejected.** A separate `## Paths` table in the plan header:
  the dispatch envelope pastes task blocks, not the header, so the line would
  not reach the implementer. A new disposition name for approved deferrals:
  `ignored` already carries `person_approved`, and one key for "the person
  said so" is simpler than two.

## Constraints

- No hub file changes; the ticket is Standard.
- Skill bodies stay under 250 lines and under their word ceilings.
- `tests/test-review.py` forbids the literal `"note"` in the review script.
- Requires landed: none.

## Research

- Verdict: none — no library or API changes.

## Settled

- **The `Path:` line lives in each task block, not in the plan header.** The
  envelope pastes task blocks; a header table would not reach the writer.
- **An approved deferral reuses `person_approved`, not a new disposition.**
  One key already means "the person said so" for `ignored`; a second name
  for the same fact is more surface for the same meaning.
- **The security-lens flag is copied into `review.json` rather than read from
  `fingerprint-start.json` by `record`.** `record` already reads
  `review.json`; one file is the record of the run.

## Open questions

- none
