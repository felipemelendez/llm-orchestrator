# The cadence — the full text

This is the procedure the `cadence` skill points at. It applies to a project
that has `docs/llm-orchestrator/cadence.json` with `"enabled": true`, and it
governs every change to production code or tests. Docs-only edits are out of
scope.

A controller (the session in the main context) dispatches seats. A seat is a
fresh agent with one job, one brief, and one report. The controller never
reviews or gates work it wrote itself, and neither does any seat.

Contents: steps 0-6 · rounds · the whole-system audit · the project files · the
lock · evidence and the ledger row · seat rules · running seats on Codex · the
honest boundary.

---

## Step 0 — brief review

A fresh read-only seat reads the brief and the tree, and returns three things.

**Claim verification.** Every `file:line`, symbol and mechanism the brief
asserts is confirmed against the tree with its real location, or marked wrong
with what is actually there and the correction. A brief that names a line that
moved sends an implementer to the wrong place, and the implementer will not
notice.

**The headline scene.** Walk the change through the contract as written: does it
fire, does it fire once, and what does the person on the other end see? Report
each scene as sound, silent (the contract does not say) or contradictory (the
contract says two things).

**Tier and split.**

- Tier is `FULL` unless `LOCAL` is argued file by file in the report. `LOCAL` is
  available only when every file the brief will touch falls in a low-blast-radius
  class: a test, a doc, a fixture, a dev-only screen, a generated file, or a
  presentational leaf that imports nothing from the project's hub list. Any file
  under a directory the project's `LAWS.md` names as a hub, and any file whose
  name carries one of the project's risk words, is `FULL`. The default is
  `FULL`; the burden is on the argument for `LOCAL`.
- The brief is split into sequential tickets, each with its own brief, when it
  touches more than about fifteen production files, or two of the hub files, or
  two runtimes (native and managed, two languages, two services). The seat
  proposes the cut with disjoint file sets; the controller writes the briefs.

Template: [references/brief-review.md](references/brief-review.md).

## Step 1 — the implementer

A fresh seat in its own worktree, dispatched with the brief, the seat rules and
the base commit. It writes the failing test first for every mechanism it adds,
pastes the red line, then makes it green. A pin that passes with its mechanism
removed is worthless, so each new test is proven red on the unfixed tree before
the fix exists.

It reverts every mutation it makes outside its own change and proves the revert
with `shasum` or `cmp`. It runs the project's floors unpiped, reading counts
from a log rather than from `| tail`, which reports the exit status of `tail`.

Template: [references/implementer.md](references/implementer.md).

## Step 2 — the blind pair

Two review seats on their own copies of the implementer's tree. They are never
shown each other's findings and never shown the implementer's report; each
re-derives the change from the tree.

- **The spec seat** gets dense `file:symbol` pressure areas and the spec. It
  answers: does this implement what was specified, and where does the code
  disagree with itself?
- **The plain-language adversarial seat** gets the scene in plain words and the
  harm ranking, and no `file:line` pointers on purpose. It follows whatever
  looks weakest and tries to make the wrong thing happen.

Independence comes from the brief as much as from the model. The two seats find
different top defects on most changes; that difference is the value, so never
merge their briefs and never let one see the other. Two seats, never a third:
a third reviewer adds cost and agreement, not coverage. The pair never debates
and is never asked to reconcile — reconciling is the refuter's job, and the
controller's.

Findings are neutral tickets: `state → wrong output → rank → EXECUTED (with the
failing line) | REASONED (with file:symbol)`. Ranks come from the project's harm
ranking in `LAWS.md`. Every catastrophic or serious finding carries a scene line
— `SCENE: given <state>; when <action>; expect <observable>` — executable enough
that a fixer can write a pin from it without reading the implementation.

A longer report is not a better one, and the adjudicator is told to ignore
length.

Templates: [references/reviewer-spec.md](references/reviewer-spec.md),
[references/reviewer-plain.md](references/reviewer-plain.md).

## Step 2b — the refuter

A fresh read-only seat, the first to see both reports. It never sees the
implementer's report. It returns the union draft, one line per finding in harm
order, each carrying its origin and, where two findings converged, both origins:

- `PROMOTED <rank> <origin> — <state → wrong output> — PROOF: <file:line, or the
  executed probe and its failing line>`, keeping the scene line verbatim.
- `DROPPED <rank> <origin> — <one sentence> — REFUTED BY: <file:line whose code
  makes the claimed state impossible or the claimed output correct>`.
- `UNRESOLVED <rank> <origin> — <one sentence> — WHY: <what it could not settle>`.

Its laws: the burden is on it to drop, and doubt promotes. Converged findings
merge and keep the higher rank. It never resolves a disagreement toward the
longer or the more confident report — length and certainty are not evidence.
It re-ranks downward only with a citation, never upward without one.

The plugin's own review workflow uses the same shape. `workflows/review-diff.js`
carries a verdict schema whose fields are `index`, `refuted`, `method`
(`executed` or `reasoned`) and `reason`; `refuted: false` is a promotion,
`refuted: true` is a drop, and a finding the refuter did not judge is
unresolved. Keep those names when wiring a refuter seat to that workflow so the
two cannot drift.

Template: [references/refuter.md](references/refuter.md).

## Step 3 — the union and the severity rule

The controller adjudicates the promoted and unresolved list only, marking each
item required, ruled (with the ruling), deferred (to a named ticket) or a
candidate. It records `promoted / dropped / raw` for the ledger row and writes
the result to `<notes_dir>/<TICKET>_UNION.md`, which the fixer and the gate seat
read.

The result is a union, not a consensus: a finding one seat raised and the other
never looked at is still a finding. Report everything, then filter by citation —
never by agreement.

Then the severity rule decides whether there is a round at all:

- Any catastrophic or serious finding, or any required spec item → step 4 (the
  fixer) then step 5 (the gate). That is round 1.
- Mild only → no fixer seat and no gate seat. The controller folds the mild
  items into the landing with a firsthand red witness (it watches the pin fail
  before the fix and pass after), and runs the gate script inside the landing,
  saving its complete output as `<notes_dir>/<TICKET>_GATE_report.md` — the
  script prints `GATE Started:` and `Finished:` and ends with `EXIT=<n>`, which
  is the line the landing check reads. Every landing has that file, whether a
  seat or the script wrote it.
- On that path the controller may write the mild fix itself, with a firsthand
  red witness, because the gate script and the full landing floors still run on
  that change. It is the one sanctioned exception to never self-verify.

## Step 4 — the fixer

A fresh seat in the implementer's worktree. For each union item, **before it
opens the current implementation of the hunk**, it writes the pin from the
item's scene line and watches it fail. Only then does it read the hunk and fix.
A pin written after reading a wrong implementation tends to mirror that
implementation and pass against it.

The fix is minimal: no drive-by refactors, no reformatting, nothing the union
did not ask for.

Template: [references/fixer.md](references/fixer.md).

## Step 5 — the gate: the script, then the seat

### 5a — `scripts/orch-cadence-gate.sh`

The deterministic half, run first, on a throwaway copy of the fixed tree:

    orch-cadence-gate.sh <path-to-tree> <base-sha> [--no-typecheck]
                         [--families "..."] [--config <cadence.json>]

In order: the inventory of changed files (production versus test, by the
config's globs, with comment-only changes recognised); the export sweep (every
module whose export set changed — names added and names removed, re-exports
included — with the suites that mock it); the touched families, resolved through
the config's import patterns; **file-level revert-to-red** for every changed
production file, reverting the file alone to base and running its importers plus
the changed suites that name it; the project's typecheck with a positive control
appended and then restored `cmp`-identical; and a `shasum` proof that the copy
ends byte-identical to its start.

Per-file verdicts: `REVERT_RED` (the change is pinned), `REVERT_STAYS_GREEN` (a
missing or degenerate pin — the seat must close it by hand),
`REVERT_RED_BY_LOAD_FAILURE` (the red is breakage, not proof), `COMMENT_ONLY`,
`NEW_FILE`, `NATIVE`, `RULES`. An unknown runner profile prints
`RUNNER_UNKNOWN` and skips that step loudly; a silent skip is the failure this
whole step exists to prevent.

Every count is read from a log. The script stamps `Started:` and `Finished:` and
prints `EXIT=<n>` as its last line. It makes its own copy and never mutates the
tree it is pointed at.

### 5b — the gate seat

A fresh seat on the same copy. It reads the script's report first and never
repeats its steps. It does only what needs judgement:

1. Replay every reviewer probe on the fixed tree.
2. Revert each union item's **hunk** alone (not the file) to the pre-fix state,
   run the pin, expect red, restore, prove by `shasum`.
3. The degenerate-pin check: for each pin the fixer named, remove the mechanism
   the pin claims to protect, run the pin, expect red, restore.
4. Novel mutations targeted at the changed hunks, typically three. The count is
   evidence, never a pass threshold: a mutation-clean tree is not a fault-free
   tree.
5. Anything the script reported as `RUNNER_UNKNOWN`, skipped or
   `REVERT_STAYS_GREEN`, done by hand and said so.

Verdict: `PASS`, `PASS-with-fixes` (listed and ranked; mild-only means the
controller folds them at landing), or `FAIL`. The report's last line is
`EXIT=0` on a pass, else `EXIT=1`.

Template: [references/gate-seat.md](references/gate-seat.md).

## Step 6 — landing

The project's full floors, unpiped, every count read from a log. The firsthand
red witness for any folded mild fix. Then the five evidence files, in
`notes_dir` and **before the commit** — the seats already wrote them there, so
nothing is copied — because `--commit-msg` runs `--landing <ticket>` whenever
the commit subject matches the `ticket_re` from `cadence.json`, and that check
reads the files as they stand at commit time. Then a commit by explicit
pathspec — never `git add -A`, which sweeps in whatever another seat left
behind — and one ledger row.

## Rounds

A gate finding that is catastrophic or serious opens **round 2**: a fresh fixer
on the delta, then 5a and 5b again on the delta. A ticket that would enter
**round 3** stops and goes back to the brief-review seat with every finding
attached; the seat returns a corrected brief or a split, and the ticket
re-enters at step 1 if the design changed, or step 4 if it did not. **There is
no round 4.** A ticket that needs a third round is more likely mis-specified
than under-reviewed, and step repetition without a stop condition is the common
way a multi-agent run burns a day.

## The whole-system audit

Before a phase ships — not per ticket — the controller runs one read-only lens
per domain of the system (one seat each; the domains come from the project's
architecture, not from a fixed list), plus a final blind plain-language pass
over the head that all of them saw. The audit repeats on the new head until a
pass reports nothing catastrophic and nothing serious.

## The project files

| File | What it holds |
|---|---|
| `docs/llm-orchestrator/LAWS.md` | the constitution: mission, promises, harm ranking, rulings, standing constraints, model seats, the standard of work, the handoff law |
| `docs/llm-orchestrator/cadence.json` | the switch, the runner profile, the path classes, `notes_dir`, `ticket_re`, `lock_extra` |
| `docs/llm-orchestrator/LOCK.sha256` | the manifest of locked content |
| `docs/llm-orchestrator/HANDOFF_TEMPLATE.md` | the handoff shape: state only |
| `docs/llm-orchestrator/DESIGN_RULINGS.md` | the controller's per-ticket design rulings, append-only, dated |
| `docs/llm-orchestrator/TRAPS.md` | traps and procedures learned, append-only, dated |
| `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh` | the git layer, versioned in the project |
| `<notes_dir>/<TICKET>_*_report.md` | the landing evidence |

Templates for the four markdown files: [references/laws.md](references/laws.md),
[references/handoff.md](references/handoff.md),
[references/design-rulings.md](references/design-rulings.md),
[references/traps.md](references/traps.md). The hook text is
[references/commit-msg](references/commit-msg).

**The handoff law.** A handoff is state only, on the template: where the world
is, one line per live tree, one line per landing, what is left in order, what
only the owner decides, the per-ticket numbers, and proposed amendments. It
never restates the laws (it points at them) and never carries the history of
what each seat did — that is the ledger row the handoff line cites. It does not
inherit from the previous handoff; it supersedes it whole. The kickoff prompt is
the template's last section, filled in.

## The lock

The locked set is `docs/llm-orchestrator/LAWS.md`,
`docs/llm-orchestrator/cadence.json`, `.claude/settings.json` (it carries the
deny rules), `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh`, the
FIRST `<!-- ORCH:LAWS:START -->` … `<!-- ORCH:LAWS:END -->` section of
`CLAUDE.md` and of `AGENTS.md` (that pair only — the rest of both files stays
writable, so memory and onboarding commands keep working; a file carrying a
second `START` marker, or a `START` with no matching `END`, is refused for every
edit, because a second or unclosed section is how a locked one gets shadowed),
plus anything the project lists in
`lock_extra`. `LOCK.sha256` is not in its own manifest — a file cannot record
its own hash; it is protected by the deny rule and the guard.

An amendment is a commit that satisfies all three: its message carries
`Ruling <N>` where N is greater than the highest ruling number in the laws; the
staged `LAWS.md` records that ruling; and `LOCK.sha256` was rewritten under
`ORCH_CADENCE_UNLOCK=1`. Any one of the three alone is text the agent wrote
about itself.

`ORCH_CADENCE_UNLOCK=1` is set by the person, in the environment, when they
launch the session — never in a settings file, and never by an agent, because
the guard refuses the assignment. The re-lock and the ruling commit happen
inside that session. Three things hold that shape: the unlock is honoured only
when no settings file in scope names `ORCH_CADENCE_UNLOCK`; in cadence mode a
command that assigns `ORCH_CADENCE_UNLOCK`, `ORCH_DISABLED_HOOKS`,
`ORCH_HOOK_PROFILE` or any `ORCH_ALLOW_*` is refused, while naming one in prose
passes; and a session holding the unlock says so, printing `UNLOCKED` in its
verdict line.

A seat that believes a law is wrong writes a proposed amendment into the handoff
and keeps working under the law as written.

## Evidence, the verdict line, and the ledger row

**Evidence naming**, under the `notes_dir` from `cadence.json`:
`<TICKET>_BRIEFREV_report.md`, `<TICKET>_REV1_report.md`,
`<TICKET>_REV2_report.md`, `<TICKET>_REFUTE_report.md`,
`<TICKET>_GATE_report.md`. Each carries `Started:` and `Finished:` stamps later
than the base commit's author date; the gate report's last line is `EXIT=0`.

`orch-cadence-check.sh` carries the modes `--verdict` (the session-start line),
`--lock` (rewrite `LOCK.sha256`; the only writer, and it refuses to run over an
existing lock without `ORCH_CADENCE_UNLOCK=1`), `--landing <ticket>`,
`--commit-msg <msgfile>` (what the git hook calls: it runs `--landing <ticket>`
as well whenever the commit subject matches the `ticket_re` from
`cadence.json`), `--audit <rev>` (the same check in CI, against a commit) and
`--version`.

`--landing <ticket>` checks presence, stamps and that final `EXIT=0`. It grades
no content: it is a check that the cadence ran, not a check that it ran well.
Nothing but a reader can do the second.

**The verdict line** is what `--verdict` prints at session start, always
beginning `cadence:` — for example `cadence: LAWS.md (ruling <N>) · lock OK`. A
project with `LAWS.md` and no `cadence.json` sees `cadence: LAWS.md present,
cadence.json absent — run /llm-orchestrator:cadence-init`. A session holding the
unlock sees ` · UNLOCKED` appended. If a session printed no such line, the
enforcement layer did not load, and a seat should say so before anything else.

**The ledger row** is one line per landing, appended to
`<notes_dir>/LEDGER.md`: tier · seats · rounds · wall-clock
(impl / pair / refuter / fixer / gate / landing) · promoted / dropped / raw. The
wall-clock numbers come from the seats' stamps. Per-stage timing tables are not
kept; the row is the record.

Any finding class seen a second time across tickets is named at the landing and
either pointed at the deterministic check that now catches it, or ticketed for
one. A class re-found by a review seat every ticket is a check waiting to be
written.

## Seat rules

Every seat's dispatch carries [references/seat-rules.md](references/seat-rules.md)
by reference. In short: spawn ceiling 0 for seats; work only where the dispatch
names; `Started:` and `Finished:` stamps on every status block; a one-line
progress note into the report at least every 15 minutes; every mutation reverted
and proven by `shasum`; floors unpiped; anything unreached marked `UNVERIFIED`
rather than silently omitted; one status block as the final message.

**The silence rule.** A seat whose tree and scratch show no file change for 20
minutes is stopped and replaced by a fresh seat told exactly what the tree
holds; its tree is left at its last shasums. The controller reads mtimes when it
checks on seats and never waits on a silent one. The 15-minute progress note is
what makes silence distinguishable from thought.

**Model discipline.** Every dispatch names its model. The plain-language
adversarial seat may run on a different model from every other seat; that is a
deliberate diversity, not a cost saving. Never resume a seat whose model
matters — a resume can land on a different model. Seats run on an uncapped
general agent type with the model named, because a capped agent definition can
kill a long read mid-way. This paragraph governs the seats a controller
dispatches; it is not about the agent files this plugin ships, which carry their
own model pins.

**Never self-verify.** The seat that wrote a change never reviews it, never
gates it and never lands it on its own word. This is the one rule the whole
cadence is built from. Its single sanctioned exception is the controller's
mild-only fold at step 3, and only because the gate script and the full landing
floors still run on that change.

## Running seats on Codex

The same shape works with processes instead of subagents: each seat is a
separate non-interactive run with its own working copy, its brief on stdin or in
a file, and its report written to the scratch folder. The controller polls the
report files rather than waiting on a pipe, which also gives it the mtimes the
silence rule needs.

Verify the command form against `codex --help` on your machine — this plugin
does not test it, and the flags for non-interactive runs, model selection and
sandbox level have moved between releases.

## The honest boundary

State this plainly wherever the cadence is described:

- Hooks and deny rules are **guardrails, not guarantees** — that is Anthropic's
  own framing, and it is right. A determined agent, a novel command spelling, or
  a harness that does not run hooks all defeat them.
- A native deny rule beats every hook and every allow rule at every scope, so
  the deny rules are the primary lock inside Claude Code and the hooks are the
  backstop.
- The git `commit-msg` layer is what holds **across tools and in CI** — but
  only after `git config core.hooksPath .githooks` is run in each clone, and
  git's own skip flag steps past it, as do `cherry-pick` and `rebase` picks.
  `orch-cadence-check.sh --audit <rev>` in CI is the cross-tool backstop that
  catches what the hook did not see.
- An install that copies the plugin rather than loading it resolves hook helpers
  relative to the hook's own directory, not through a plugin-root variable that
  only the loaded form defines.
- Whether Codex fires hooks inside subagents is **unverified**. Treat the git
  layer as the enforcement there and the hooks as a convenience on trusted
  projects.
