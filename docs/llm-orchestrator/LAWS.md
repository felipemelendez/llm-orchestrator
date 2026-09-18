# THE LAWS — LLM Orchestrator (stable; read first every session; changed only by a numbered ruling from Felipe)

This repository is the LLM Orchestrator plugin itself. These laws turn its own
cadence on in its own checkout, so the framework is developed and verified under
the process it ships. State never lives here: pending work goes in the
conversation or a temporary handoff outside Git; maintained specifications live
under `docs/specs/`; design decisions in `DESIGN_RULINGS.md`; traps in
`TRAPS.md`. An agent that believes a law is wrong proposes an amendment in its
handoff and keeps working under the law as written. Only Felipe rules.

This file is what the cadence lock protects. It changes only by a numbered
ruling, in a commit whose message carries `Ruling <N>`, with `LOCK.sha256`
rewritten under `ORCH_CADENCE_UNLOCK=1`, which the person sets in the
environment when launching that session, never in a settings file and never by
an agent. The re-lock and the ruling commit happen inside that session.

## 1. What we are building, and why

LLM Orchestrator is a Claude Code plugin and Codex install that makes agent
work proportional and truthful: small changes stay simple, consequential changes
receive independent review, valid checks are reused, temporary artifacts are
cleaned safely, and a completion claim is backed by observed execution.

**The promises — judge every line of work by them.**

- A `Verification: PASS` is only ever emitted when the hooks observed the
  named checks pass on the final source. Text never supplies evidence.
- The cadence never weakens itself silently: checker configuration, laws, the
  lock, hook definitions and deny rules change only through the ruling path.
- The plugin never destroys another session's work: no force removal, no
  stash pop, no adopting paths it did not create, no bulk deletion of documents.
- Claude and Codex get the same policy, the same completion vocabulary and the
  same cleanup helper, from the same source files.

**Harm ranking.** The severity rule reads these three classes.

- Catastrophic: a fabricated or unsupported passing verdict; a failed, empty,
  interrupted or stale check counted as passing; a protected rule changed
  without a ruling; deletion of unfinished, unique or another session's work.
- Serious: a hook that fails open on the path it guards, blocks legitimate work
  it cannot explain, exceeds its harness time limit, or attributes one
  repository's checks to another; installed copies that drift from source.
- Mild: documentation, wording, maintainability and test-strength findings
  without a demonstrated serious consequence.

## 2. The laws and rulings — never re-ask

- **Standing orders:** never commit, push, merge or tag unless Felipe asks in
  that turn; stage by explicit pathspec, never `git add -A`. Never run paid
  evaluations (`tests/evals/`) unattended. Never set or persist the unlock, the
  hook profile, the disabled-hooks list or any allow hatch; those belong to
  the person's own shell.
- **Rulings that govern the build:**
  `Ruling 1 (2026-09-17, Felipe): the proportional cadence specified in docs/specs/proportional-cadence.md applies to this repository itself, with workflow proportional, Claude and Codex execution evidence in blocking mode, and the shared task-resource cleanup; the framework verifies its own changes through its own hooks.`
- **Standing constraints:** shipped files under `scripts/`, `skills/`, `hooks/`,
  `agents/`, `commands/`, `templates/`, `workflows/` and `output-styles/` are
  production; `tests/` are tests; ordinary Markdown is documentation. After a
  shipped file changes, the installed Claude plugin copy and the Codex copied
  skill must be refreshed to byte parity before the change is called complete.
  `templates/cadence-global-block.md` and
  `skills/cadence/references/global-block.md` stay identical. Skill bodies stay
  under 250 lines (`tests/validate-skills.sh`). The Git layer (`.githooks/`
  copies, the marked instruction blocks and the local deny rules) is installed
  by `cadence-init.sh` in a session the person launches, and Git hooks stay
  inert until that person routes them; the plugin never runs `git config`.
- **Hubs:** `scripts/lib/orch-proportional-evidence.py`,
  `scripts/hooks/codex-evidence.py`, `skills/cadence/scripts/orch-cadence-check.sh`,
  `scripts/install.sh` and `hooks/hooks.json`. A change touching two of them
  is Full.

## 3. Model seats

Every dispatch names its model. Full work on verification, evidence, cleanup or
lock contracts receives two independent blind reviews: one native Codex
adversarial review inheriting the controller's model and effort, and one actual
Claude Fable 5.1 review through the read-only provider runner. Record the served
model from the receipt; a dropout is not a review and another model is never
substituted silently. Reviewers never see the implementer's conclusions or each
other's findings before reporting.

## 4. The standard of work

- **Workflow selection:** `workflow: proportional`. Choose Simple, Standard or
  Full by impact, uncertainty, affected contracts and reversibility, never by
  line count. Simple is edit, inspect the diff, run the applicable existing
  suite, deliver. Standard adds one independent review. Full follows the
  cadence skill's Full path. Writers may run checks and inspect their diff but
  cannot supply a required independent review or gate.
- **Checks:** the applicable suites under `tests/`, invoked directly as
  `bash tests/test-<name>.sh` or `python3 tests/test-<name>.py` from this
  checkout, one command per invocation, no wrapper, pipe or flag prefix. The
  full suite is `bash tests/run-all.sh` and is the right check for hub changes;
  it is a script, so name the individual suites it ran when claiming PASS.
  Run the two legacy evidence suites through
  `python3 tests/test-proportional-install.py`, which captures their output;
  the bare ledger suite prints a fixture label the recognizer treats as empty.
- **Evidence route:** in Claude, checks are observed by the native Bash tool;
  give each suite a tool timeout longer than its run (the evidence suite takes
  over two minutes) and prefer suites with concise output, because a command
  the harness backgrounds or an output it persists to a file cannot be
  confirmed by the hook.
  In Codex, run each check through `scripts/verification/codex-verify.py` with
  fresh absolute receipt and output paths in task-owned scratch. Provider
  receipts and child prose are never test results. End with
  `Verification: PASS | PENDING | BLOCKED | NOT APPLICABLE — reason`.
- **Cleanup:** temporary reviews, copies, receipts and logs live in task-owned
  scratch created with `skills/cadence/scripts/orch-task-resources.py`; finish
  the task after consumers stop and deliverables are preserved. Keep this
  file, the specs, the evidence docs and the field records.
- **Talking to the owner:** lead with the outcome, one shape header, plain
  language, complete or incomplete stated as such with the exact limitation.

## 5. The handoff law

A handoff is state only: where the tree is, what is verified and by which
observed checks, what remains in order, what only Felipe decides, and proposed
amendments. It points at these laws rather than restating them, and it lives
outside Git unless Felipe asks for a maintained document.
