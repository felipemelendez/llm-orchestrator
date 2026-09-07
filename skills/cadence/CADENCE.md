# The cadence — the full text

This is the procedure the `cadence` skill points at. It applies to a project that
has `docs/llm-orchestrator/cadence.json` with `"enabled": true`, and it governs
every change to production code or tests; docs-only edits are out of scope.

A controller (the session in the main context) dispatches seats. A seat is a
fresh agent with one job, one brief and one report. The controller never reviews
or gates work it wrote itself, and neither does any seat.

Contents: steps 0-6 · rounds and the stop rule · the whole-system audit · the
project files · the lock · the amendment mechanism · evidence and the ledger row ·
seat rules · environment · running seats on Codex · the honest boundary.

---

## Step 0 — brief review

A fresh read-only seat reads the brief and the tree, and returns five things.

**Claim verification.** Every `file:line`, symbol and mechanism the brief
asserts is confirmed against the tree with its real location, or marked wrong
with what is actually there and the correction. A brief that names a line that
moved sends an implementer to the wrong place, and it will not notice.

**The headline scene.** Walk the change through the contract as written: does it
fire, does it fire once, and what does the person on the other end see? Each
scene is sound, silent (the contract does not say) or contradictory (it says
two things).

**Class.** Every ticket is `CODE` unless `PROSE` is argued file by file in the
report. `PROSE` means nothing the ticket touches is executed, or read by any
program to decide behaviour — no script, hook, config, rule file, JSON, workflow
or template a program consumes, whatever runs it — only prose a person reads:
skill bodies, references, docs, markdown templates. A git hook, a settings file
and any JSON a program reads are `CODE`; one such file in the set makes the
ticket `CODE`. The default is `CODE`; the burden is on the `PROSE` argument.

**Split.** The brief is split into sequential tickets, each with its own brief,
when it touches more than about fifteen production files, or two files the
project's laws name as hubs, or two runtimes (native and managed, two languages,
two services). The seat proposes the cut with disjoint file sets; the controller
writes the briefs.

**Active skips.** Which stage skips are live in `<notes_dir>/CADENCE_STATE.md`,
and whether each still qualifies under the amendment mechanism; with no state
file the answer is "active skips: none".

Template: [references/brief-review.md](references/brief-review.md).

## Step 1 — the implementer

A fresh seat in its own worktree, dispatched with the brief, the seat rules and
the base commit. It writes the failing test first for every mechanism it adds,
pastes the red line, then makes it green: a pin that passes with its mechanism
removed is worthless, so each new test is proven red on the unfixed tree first.
It reverts every mutation it makes outside its own change and proves the revert
with `shasum` or `cmp`, and runs the project's floors unpiped, reading counts
from a log rather than from `| tail`, which reports the exit status of `tail`.

Template: [references/implementer.md](references/implementer.md).

## Step 2 — the blind pair

Two review seats on their own copies of the implementer's tree, never shown each
other's findings and never shown the implementer's report; each re-derives the
change from the tree.

- **The spec seat** gets dense `file:symbol` pressure areas and the spec. It
  answers: does this implement what was specified, and where does the code
  disagree with itself?
- **The plain-language adversarial seat** gets the scene in plain words and the
  harm ranking, and no `file:line` pointers on purpose: it follows whatever looks
  weakest and tries to make the wrong thing happen.

Independence comes from the brief as much as from the model: never merge their
briefs and never let one see the other. Two seats, never a third — a third adds
cost and agreement, not coverage. The pair never debates and is never asked to
reconcile; that is the refuter's job, and the controller's.

Findings are neutral tickets: `state → wrong output → rank → EXECUTED (with the
failing line) | REASONED (with file:symbol)`. Ranks come from the project's harm
ranking in `LAWS.md`. Every catastrophic or serious finding carries a scene line —
`SCENE: given <state>; when <action>; expect <observable>` — executable enough that
a fixer can write a pin from it without reading the implementation. A longer report
is not a better one, and the adjudicator ignores length.

Templates: [references/reviewer-spec.md](references/reviewer-spec.md),
[references/reviewer-plain.md](references/reviewer-plain.md).

## Step 2b — the refuter

It runs when the two reports together exceed eight findings, or when any
catastrophic or serious finding is reasoned rather than executed. Otherwise the
controller adjudicates the raw reports directly, the ledger row says so, and its
own adjudication is saved as `<TICKET>_REFUTE_report.md`, opening `Status:`,
`Started:`, then `refuter: skipped under the threshold (<n> findings, every
catastrophic and serious one executed)`, the union lines, `Finished:` — so the
fifth evidence file exists and says who wrote it.

A fresh read-only seat, the first to see both reports and never the implementer's.
It returns the union draft, one line per finding in harm order, each carrying its
origin and, where two findings converged, both origins:

- `PROMOTED <rank> <origin> — <state → wrong output> — PROOF: <file:line, or the
  executed probe and its failing line>`, keeping the scene line verbatim.
- `DROPPED <rank> <origin> — <one sentence> — REFUTED BY: <file:line whose code
  makes the claimed state impossible or the claimed output correct>`.
- `UNRESOLVED <rank> <origin> — <one sentence> — WHY: <what it could not settle>`.

Its laws: the burden is on it to drop, and doubt promotes. Converged findings
merge and keep the higher rank. It never resolves toward the longer or the more
confident report — length and certainty are not evidence — and re-ranks downward
only with a citation, never upward without one. The plugin's own
`workflows/review-diff.js` carries the same verdict schema — `index`, `refuted`,
`method` (`executed` or `reasoned`), `reason`; `refuted: false` is a promotion,
`refuted: true` a drop, an unjudged finding unresolved. Keep those names so the
seat's prose and the schema cannot drift.

Template: [references/refuter.md](references/refuter.md).

## Step 3 — the union and the severity rule

The controller adjudicates the promoted and unresolved list only, marking each
item required, ruled (with the ruling), deferred (to a named ticket) or a
candidate. It records `promoted / dropped / raw` for the ledger row and writes the
result to `<notes_dir>/<TICKET>_UNION.md`, which the fixer and the gate seat read.
The result is a union, not a consensus: a finding one seat raised and the other
never looked at is still a finding. Report everything, then filter by citation,
never by agreement.

Then the severity rule decides whether there is a round at all:

- Any catastrophic or serious finding, or any required spec item → step 4 (the
  fixer) then step 5 (the gate). That is round 1.
- Mild only → no fixer seat and no gate seat. The controller folds the mild
  items into the landing with a firsthand red witness, and runs the gate script
  inside the landing, saving its complete output as
  `<notes_dir>/<TICKET>_GATE_report.md` — the script prints `GATE Started:` and
  `Finished:` and ends with `EXIT=<n>`, the line the landing check reads. Every
  landing has that file, whether a seat or the script wrote it.
- On that path the controller may write the mild fix itself, with a firsthand
  red witness, because the gate script and the full landing floors still run on
  that change. It is the one sanctioned exception to never self-verify.

## Step 4 — the fixer

A fresh seat in the implementer's worktree. For each union item, **before it
opens the current implementation of the hunk**, it writes the pin from the
item's scene line and watches it fail. Only then does it read the hunk and fix:
a pin written after reading a wrong implementation mirrors it and passes. The fix
is minimal: no drive-by refactors, no reformatting, nothing the union did not ask
for.

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
appended and then restored `cmp`-identical; and a `shasum` proof that the copy ends
byte-identical to its start.

Per-file verdicts: `REVERT_RED` (the change is pinned), `REVERT_STAYS_GREEN` (a
missing or degenerate pin — the seat must close it by hand),
`REVERT_RED_BY_LOAD_FAILURE` (the red is breakage, not proof), `COMMENT_ONLY`,
`NEW_FILE`, `NATIVE`, `RULES`. An unknown runner profile prints `RUNNER_UNKNOWN`
and skips that step loudly; a silent skip is the failure this whole step exists
to prevent. Every count is read from a log. The script stamps `Started:` and
`Finished:`, prints `EXIT=<n>` as its last line, makes its own copy and never
mutates the tree it is pointed at.

### 5b — the gate seat

On a `CODE` ticket the gate seat always runs. On a `PROSE` ticket it is skipped:
the gate script and the landing floors stand in its place, and
`<TICKET>_GATE_report.md` is the gate script's complete output.

A fresh seat on the same copy. It reads the script's report first, never repeats
its steps, and does only what needs judgement:

1. Replay every reviewer probe on the fixed tree.
2. Revert each union item's **hunk** alone (not the file) to the pre-fix state,
   run the pin, expect red, restore, prove by `shasum`.
3. The degenerate-pin check: for each pin the fixer named, remove the mechanism
   the pin claims to protect, run the pin, expect red, restore.
4. Novel mutations targeted at the changed hunks, typically three. The count is
   evidence, never a pass threshold: a mutation-clean tree is not fault-free.
5. Anything the script reported as `RUNNER_UNKNOWN`, skipped or
   `REVERT_STAYS_GREEN`, done by hand and said so.

Verdict: `PASS`, `PASS-with-fixes` (listed and ranked; mild-only means the
controller folds them at landing), or `FAIL`; the report's last line is `EXIT=0` on
a pass, else `EXIT=1`. Every gate finding also carries
`CLASS: <short noun phrase>` — the kind of hole, not the instance. A round after
the first receives every earlier gate report's `CLASS:` lines and writes either
`CLASS: same as round <k>: <string>`, that round's string verbatim, or a new
string; the controller compares them literally, never by meaning, and never names
a class itself. The stop rule below is what reads them.

Template: [references/gate-seat.md](references/gate-seat.md).

## Step 6 — landing

The project's full floors, unpiped, every count read from a log, and the branch's CI
run on the shared runner green — every local floor here runs on one operating
system, and a suite has passed on one and failed on the other. The firsthand red
witness for any folded mild fix. Then the five evidence files (where no gate seat
ran, the gate report is the gate script's complete output; where the refuter was
skipped, the refuter report is the controller's own adjudication), in `notes_dir`
and **before the commit**, because `--commit-msg` runs `--landing <ticket>` whenever
the commit subject matches the `ticket_re` from `cadence.json` and reads the files
as they stand at commit time. Then a commit by explicit pathspec — never
`git add -A`, which sweeps in whatever another seat left behind — and one ledger
row.

## Rounds and the stop rule

A gate finding that is catastrophic or serious opens the next round: a fresh fixer
on the delta, then 5a and 5b again on the delta.

The ticket **stops** when the new round's finding carries the same class as the
previous round's — when its `CLASS:` line names an earlier round's string
verbatim. A repeated class is a design fault, not a missed line: the
ticket returns to step 0 with every finding attached and re-enters at step 1. A
new-class finding whose fix is one function, on a design that held under the
gate's own mutation battery, is a bounded round, not a stop. Two returns to step 0
on one ticket and the owner rules. Count classes, not rounds: step repetition
without a stop condition is the common way a multi-agent run burns a day.

## The whole-system audit

Before a phase ships — not per ticket — the controller runs one read-only lens per
domain of the system (one seat each, by the project's architecture, not a fixed
list), plus a final blind plain-language pass over the head that all of them saw.
It repeats on the new head until a pass reports nothing catastrophic or serious.

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
| `<notes_dir>/CADENCE_STATE.md` | the stage skips, append-only |

Templates for the four markdown files: [references/laws.md](references/laws.md),
[references/handoff.md](references/handoff.md),
[references/design-rulings.md](references/design-rulings.md),
[references/traps.md](references/traps.md). The hook text is
[references/commit-msg](references/commit-msg).

**The handoff law.** A handoff is state only, on the template: where the world is,
one line per live tree, one line per landing, what is left in order, what only the
owner decides, the per-ticket numbers, and proposed amendments. It never restates
the laws (it points at them) and never carries what each seat did — that is the
ledger row it cites. It supersedes the previous handoff whole; the kickoff prompt
is the template's last section, filled in.

## The lock

The locked set is `docs/llm-orchestrator/LAWS.md`,
`docs/llm-orchestrator/cadence.json`, `.claude/settings.json`,
`.githooks/commit-msg`, `.githooks/orch-cadence-check.sh`, the FIRST `<!--
ORCH:LAWS:START -->` … `<!-- ORCH:LAWS:END -->` section of `CLAUDE.md` and
`AGENTS.md` (that pair only — the rest stays writable, so memory and onboarding
work; a second `START`, or one with no `END`, is named by the init and the lock
and refused at the commit, nothing refusing the edit itself, that being how a
locked one gets shadowed), plus `lock_extra`. The six FILES are held by the deny
rules, the marked section by the alarm alone (a rule addresses a whole file only),
and `LOCK.sha256`, which cannot record its own hash, by its deny rule.

**Two layers, in this order of trust.**

**Layer 1 — the native `Edit(...)` deny rules** in `.claude/settings.json`. The
primary: deny beats every hook and every allow rule at every scope. They cover the
built-in file tools, the recognised Bash file commands and every redirection
target, so the careless write fails here first. A project verifies once, in a live
session, what they cover on its machine; with Claude Code's sandbox enabled they
bind every subprocess too, and the plugin never enables it for anyone. What they
do not catch: a write from a subprocess where that sandbox is off.

**Layer 2 — the alarm**, the guarantee a change is seen: the end-of-turn verdict,
the session-start line, the git `commit-msg` hook and `--audit` in CI. It stops
nothing; it names a change after the fact — at the end of the turn, at the next
session start, at the commit where the hook is installed and not skipped, and in
CI through `--audit` when it was not. It never prevents a write.

**The boundary:** a careless write fails at once and loudly, but a write the deny
rules do not stop — a computed path, an archive, an interpreter, a script that
opens the file itself — happens, and layer 2 names it afterwards. A shell guard
that judged each command by its text was tried and removed; text matching cannot
be made tight, and the alarm already named what it caught.

An amendment is a commit that satisfies all three: its message carries
`Ruling <N>`, greater than the highest ruling number in the laws; the staged
`LAWS.md` records that ruling; and `LOCK.sha256` was rewritten under
`ORCH_CADENCE_UNLOCK=1`. Any one alone is text the agent wrote about itself.

`ORCH_CADENCE_UNLOCK=1` is set by the person, in their own shell, at launch —
never in a settings file, never inside a command an agent runs, because the unlock
guard refuses any command naming it. The re-lock and the ruling commit happen
inside that session. Three things hold that shape: the unlock is honoured only when
no settings file in scope names it; in cadence mode a command whose text contains
`ORCH_CADENCE_UNLOCK`, `ORCH_DISABLED_HOOKS`, `ORCH_HOOK_PROFILE` or `ORCH_ALLOW_`
is refused whatever the verb — not to set one, not to read one, not to search for
one, a cost the refusal states as it sends the work to the person's own shell; and
a session holding the unlock prints `UNLOCKED` in its verdict line. That guard
knows four names and no grammar: a name assembled at runtime is the residual.

A seat that believes a law is wrong writes a proposed amendment into the handoff
and keeps working under the law as written.

## The amendment mechanism

The orchestrator may skip a stage on its own — only downward, only per class, only
citing three ledger rows — and exactly two stages are skippable. The gate seat, on
`CODE` only, after three landed `CODE` rows with no catastrophic and no serious
gate-seat finding. The refuter, after three landed rows of the ticket's class on
which it dropped nothing and re-ranked nothing. Nothing else: the refuter below the
finding threshold and the gate seat on a `PROSE` ticket are rules of steps 2b and
5b, not skips, and need no rows, no line and no expiry. Every skip expires with the
fifth landed ticket after the one that wrote it and must re-qualify on three fresh
rows. Any catastrophic finding, by any seat, on any later ticket of any class
re-arms every live skip permanently until the owner rules otherwise; the controller
appends the `re-armed:` line at that ticket's union, before step 4.

Skips live in `<notes_dir>/CADENCE_STATE.md` — append-only, dated, one entry per
physical line with its rows and its expiry. The rule the check script implements:
its `--verdict` appends ` · skips: <n>` while a state file exists, where `<n>`
counts the `skip:` lines not cancelled by a later `re-armed:` or `expired:` line
naming the same stage and the same class; the orchestrator appends `expired:
<stage> · class <CODE|PROSE> · <date>` when the fifth landed ticket after the
skip's own passes. The brief-review seat reports which are active and whether each
still qualifies. Everything else — the pair, never self-verify, the harm ranking,
the stop rule, the lock's shape and every threshold in this text — changes only by
a numbered ruling under the unlock.

Template: [references/cadence-state.md](references/cadence-state.md).

## Evidence, the verdict line, and the ledger row

**Evidence naming**, under the `notes_dir` from `cadence.json`:
`<TICKET>_BRIEFREV_report.md`, `<TICKET>_REV1_report.md`, `<TICKET>_REV2_report.md`,
`<TICKET>_REFUTE_report.md`, `<TICKET>_GATE_report.md`. Each carries `Started:` and
`Finished:` stamps later than the base commit's author date; the gate report's last
line is `EXIT=0`. Where the refuter was skipped under the threshold the fourth file
is the controller's own adjudication, and where no gate seat ran the fifth is the
gate script's complete output; each says so in its first line.

`orch-cadence-check.sh` carries the modes `--verdict` (the session-start line),
`--lock` (rewrite `LOCK.sha256`; the only writer, and it refuses to run over an
existing lock without `ORCH_CADENCE_UNLOCK=1`), `--landing <ticket>`,
`--commit-msg <msgfile>` (what the git hook calls: it runs `--landing <ticket>` too
whenever the commit subject matches the `ticket_re` from `cadence.json`), `--audit
<rev>` (the same check in CI, against a commit) and `--version`. `--landing
<ticket>` checks presence, stamps and that final `EXIT=0`. It grades no content: it
checks that the cadence ran, not that it ran well, and nothing but a reader can do
the second.

**The verdict line** is what `--verdict` prints at session start, always beginning
`cadence:` — for example `cadence: LAWS.md (ruling <N>) · lock OK`. A project with
`LAWS.md` and no `cadence.json` sees `cadence: LAWS.md present, cadence.json
absent — run /llm-orchestrator:cadence-init`. A session holding the unlock sees
` · UNLOCKED` appended. Where a `CADENCE_STATE.md` exists the line ends with
` · skips: <n>`, counted as the amendment mechanism defines; with no state file
that suffix is absent rather than zero. If a session printed no such line, the
enforcement layer did not load, and a seat says so before anything else.

**The ledger row** is one line per landing, appended to `<notes_dir>/LEDGER.md`:
ticket · class · rounds · wall-clock (impl / pair / refuter / fixer / gate /
landing) · raw / promoted / dropped · first found by stage (brief review, spec
seat, plain seat, gate — catastrophic and serious counted separately for each) ·
gate finding class · minutes lost to the environment · skips applied. The
wall-clock numbers come from the seats' stamps. *First found by stage* and *gate
finding class* exist so the row says which stage paid: a stage no finding is ever
first found by is one the amendment mechanism may retire — and only the gate seat
and the refuter are retirable. Per-stage timing tables are not kept; the row is
the record.

Any finding class seen a second time across tickets is named at the landing and
either pointed at the deterministic check that now catches it, or ticketed for one.

## Seat rules

Every seat's dispatch carries [references/seat-rules.md](references/seat-rules.md)
by reference. In short: spawn ceiling 0 for seats; work only where the dispatch
names; `Started:` and `Finished:` stamps on every status block; a progress note
into the report at least every 15 minutes; every mutation reverted and proven by
`shasum`; floors unpiped; anything unreached marked `UNVERIFIED` rather than
silently omitted; one status block of at most twenty lines at the top of the
report, the evidence below a horizontal rule, printed as the final message. A seat
that believes a rule cost work it did not repay writes `rule friction: <rule> —
<the rows>` in that block and files its findings anyway; the brief review collects
those lines at Step 0, and no reviewer drops a finding because the wording is the
ruling's own.

**The packet rule.** One briefing packet per ticket — the base sha, the file map,
the union, the previous stage's status blocks — and a seat reads the packet its
dispatch names, not the folder around it.

**The silence rule.** A silent seat is stopped and replaced by a fresh one told
exactly what the tree holds; its tree is left at its last shasums. The controller
reads mtimes when it checks on seats and never waits on a silent one; the timings
are below.

**Model discipline.** Every dispatch names its model. The plain-language
adversarial seat may run on a different model from every other seat — deliberate
diversity, not a cost saving. Never resume a seat whose model matters: a resume
can land on a different model. Seats run on an uncapped general agent type with
the model named, because a capped definition can kill a long read mid-way. This
paragraph governs the seats a controller dispatches, not the agent files this
plugin ships, which carry their own model pins.

**Never self-verify.** The seat that wrote a change never reviews it, never gates
it and never lands it on its own word — the rule the whole cadence is built from.
Its single sanctioned exception is the controller's mild-only fold at step 3, and
only because the gate script and the full landing floors still run on that
change.

## Environment

An unattended run holds the machine awake. A seat with no file change for twenty
minutes is stopped and re-dispatched with a resume note — the controller's own move,
not a question for a person. Every seat writes a progress line every fifteen minutes,
and a harness outage is waited out and retried, never treated as a stop. In practice
a sleeping machine has cost more than every extra review round combined. Every seat
runs on a throwaway copy or a worktree: a copy is deleted the moment its seat's report
carries `Finished:` and the stage's ledger row is written, a ticket's worktree goes
when the ticket lands, and the controller lists what is still on disk in every handoff.

## Running seats on Codex

The same shape works with processes instead of subagents: each seat is a separate
non-interactive run with its own working copy, its brief on stdin or in a file,
and its report written to the scratch folder. The controller polls the report
files rather than waiting on a pipe, which also gives it the mtimes the silence
rule needs. Verify the command form against `codex --help` on your machine — this
plugin does not test it, and the flags for non-interactive runs, model selection
and sandbox level have moved between releases.

## The honest boundary

State this plainly wherever the cadence is described:

- Hooks and deny rules are **guardrails, not guarantees** — Anthropic's own
  framing, and it is right. A determined agent, a novel command spelling, or a
  harness that does not run hooks all defeat them.
- A native deny rule beats every hook and every allow rule at every scope: layer
  1, the deny rules, is the primary lock inside Claude Code; layer 2 — the
  verdict, the session line, the `commit-msg` hook and `--audit` — is the record
  that names what layer 1 let through, after the fact.
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
