# THE LAWS — LLM Orchestrator (stable; read first every session; changed only by a numbered ruling from Felipe)

This repository is the LLM Orchestrator plugin itself. These laws turn its own
cadence on in its own checkout, so the framework is developed and verified under
the process it ships. State never lives here: pending work goes in the
conversation or a temporary handoff outside Git; maintained specifications live
under `docs/specs/`; design decisions in `DESIGN_RULINGS.md`; traps in
`TRAPS.md`. An agent that believes a law is wrong proposes an amendment in its
handoff and keeps working under the law as written. Only Felipe rules.

This file is what the cadence lock protects. It changes only by a numbered
ruling, in a commit whose message carries `Ruling <N>`. Felipe makes that commit
by running `skills/cadence/scripts/cadence-ruling.sh` in his own terminal: it
applies the agreed patch, re-records `LOCK.sha256` and commits. An agent
proposes the change as a patch outside Git, with its reasons, and never runs
the command.

## 1. What we are building, and why

LLM Orchestrator is a Claude Code plugin that makes agent
work proportional and truthful: small changes stay simple, consequential changes
receive independent review, valid checks are reused, temporary artifacts are
cleaned safely, and a completion claim is backed by observed execution.

**The promises — judge every line of work by them.**

- A `Verification: PASS` names checks that actually ran. A Stop hook reads the
  transcript and says so when none did; it warns rather than blocks, so the
  honesty is the agent's to supply. Text never substitutes for a check.
- The cadence never weakens itself silently: checker configuration, laws, the
  lock, hook definitions and deny rules change only through the ruling path.
- The plugin never destroys another session's work: no force removal, no
  stash pop, no adopting paths it did not create, no bulk deletion of documents.
- Claude Code and Codex, one policy. The skills stay readable anywhere, as
  instructions, with nothing enforcing them.

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
  evaluations (`tests/evals/`) unattended. Never run `cadence-ruling.sh`, and
  never set or persist the hook profile, the disabled-hooks list or any allow
  hatch; those belong to the person's own shell.
- **Rulings that govern the build:**
  `Ruling 1 (2026-09-17, Felipe): the proportional cadence specified in docs/specs/proportional-cadence.md applies to this repository itself, with workflow proportional, Claude and Codex execution evidence in blocking mode, and the shared task-resource cleanup; the framework verifies its own changes through its own hooks.`
  `Ruling 2 (2026-09-22, Felipe): Claude Code only; completion is checked once at Stop, by warning, never by blocking. Supersedes Ruling 1 where they differ.`
  `Ruling 3 (2026-09-23, Felipe): Codex is a supported harness, with the file guard and the completion check installed by install.sh --codex. On Codex the completion check's single decision:block continuation to the agent is the warning, suppressed on stop_hook_active; systemMessage and any output for the person stay forbidden. docs/llm-orchestrator/CODEX.md is reinstated. "One harness, one policy: Claude Code" is amended to "Claude Code and Codex, one policy". Supersedes Rulings 1 and 2 where they differ.`
  `Ruling 4 (2026-09-25, Felipe): Felipe applies an agreed rule change with skills/cadence/scripts/cadence-ruling.sh in his own terminal, which re-records the lock and commits the ruling, replacing the removed unlock variable; the shipped cadence files (git hooks, marked block, deny rules) are upgraded to match, workflows/ leaves the production list and cadence.json's src_roots and prod_globs, and cadence.json drops the legacy notes_dir and ticket_re. On Codex the file guard and the completion check come from the Codex plugin (codex plugin add), and install.sh --codex writes only the instructions block and, once the plugin is installed, removes the hook entries older releases added. Supersedes Ruling 3 where they differ.`
- **Standing constraints:** shipped files under `scripts/`, `skills/`, `hooks/`,
  `agents/`, `commands/`, `templates/` and `output-styles/` are production;
  `tests/` are tests; ordinary Markdown is documentation. After a
  shipped file changes, the installed Claude plugin copy must be refreshed to
  byte parity before the change is called complete.
  `templates/cadence-global-block.md` and
  `skills/cadence/references/global-block.md` stay identical. Skill bodies stay
  under 250 lines (`tests/validate-skills.sh`). The Git layer (`.githooks/`
  copies, the marked instruction blocks and the local deny rules) is installed
  by `cadence-init.sh` in a session the person launches, and Git hooks stay
  inert until that person routes them; the plugin never runs `git config`.
- **Hubs:** `scripts/lib/orch-completion-check.py`,
  `scripts/hooks/orch-verify-gate.sh`, `skills/cadence/scripts/orch-cadence-check.sh`,
  `scripts/install.sh` and `hooks/hooks.json`. A change touching two of them
  is Full.

## 3. Model seats

Every dispatch names its model. Full work on verification, evidence, cleanup or
lock contracts receives two independent blind reviews with different briefs:
one adversarial, one against the contract. Name the model of each dispatch and
record what was actually served; a refusal, a rate limit or a dropout is not
a review, and substituting another model is stated out loud, never silently.
Reviewers never see the implementer's conclusions or each other's findings
before reporting.

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
  Python suites run directly, or through their `.sh` shim so `run-all.sh`
  discovers them - `run-all.sh` finds only `*.sh`, and a suite with no shim
  silently stops running.
- **Evidence route:** in Claude, checks are observed by the native Bash tool;
  give each suite a tool timeout longer than its run (the evidence suite takes
  over two minutes) and prefer suites with concise output, because a command
  the harness backgrounds or an output it persists to a file cannot be
  confirmed by the hook.
  A child agent's report is not a test result. End with
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
