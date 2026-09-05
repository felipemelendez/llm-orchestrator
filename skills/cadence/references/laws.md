# THE LAWS — <PROJECT> (stable; read first every session; changed only by a numbered ruling from <OWNER>)

<!--
Template for `docs/llm-orchestrator/LAWS.md`. Fill every `<PLACEHOLDER>`, delete
this comment, and delete any section the project genuinely has no content for —
but not the harm ranking, which the cadence's severity rule reads.
-->

This file is the constitution of the build. It never carries state. State lives
in the session handoff (on `HANDOFF_TEMPLATE.md`, beside this file); history in
the ledger; per-ticket design rulings in `DESIGN_RULINGS.md` (append-only); the
traps and procedures learned in `TRAPS.md` (append-only). An agent that believes
a law is wrong writes a proposal in the handoff's amendments section and keeps
working under the law as written. Only the owner turns a proposal into a ruling;
nobody else edits this file.

This file is what the cadence lock protects. It is changed only by a numbered
ruling from the owner, in a commit whose message carries `Ruling <N>`, with
`LOCK.sha256` rewritten under `ORCH_CADENCE_UNLOCK=1` — a variable the person
sets in the environment when launching the session, never in a settings file and
never by an agent, since the guard refuses the assignment. The re-lock and the
ruling commit happen inside that session.

## 1. What we are building, and why

<MISSION>

**The promises — judge every line of work by them.**

<PROMISES>

**Harm ranking.** The cadence's severity rule reads these three classes: a
catastrophic or serious finding opens a fixer-and-gate round; mild-only folds
into the landing with a firsthand red witness.

<HARM_RANKING>

## 2. The laws and rulings — never re-ask

- **Standing orders, verbatim and binding:** <STANDING_ORDERS — the owner's own
  instructions, quoted word for word, that bind every session whatever the
  ticket is.>
- **Rulings that govern the build:** <RULINGS — one line each, newest last, on
  this shape: `Ruling <N> (YYYY-MM-DD, <OWNER>): <one sentence>`. N starts at 1
  and only rises. The check script reads the highest `Ruling <N>` in this file,
  and an amending commit's message must carry a higher one.>
- **Standing constraints:** <CONSTRAINTS — e.g. never commit without an explicit
  pathspec; never `git add -A`; what only the owner deploys; which trees are
  never deleted; which files another live session may be editing.>

## 3. Model seats

Every dispatch names its model. <MODEL_POLICY — which model every seat runs on,
and which single seat deliberately runs on a different one.> Independence comes
from the brief as much as from the model: the spec seat gets dense
`file:symbol` pressure areas; the plain-language adversarial seat gets the scene
and the harm ranking and no `file:line` pointers, and follows whatever looks
weakest. Never a resume for a seat whose model matters. Seats run on an uncapped
general agent type with the model named — a capped agent definition can kill a
long read mid-way.

## 4. The standard of work

- **The cadence is the `cadence` skill's `CADENCE.md`** (binding, step by step).
  Every seat's brief carries the seat rules by reference.
- **Machine budget:** <BUDGET — how many workers a reviewer runs, which stage
  runs the only full test suite, how many writers may run in parallel.>
- **The silence rule:** a seat whose tree and scratch show no file change for 20
  minutes is stopped and replaced by a fresh seat told exactly what the tree
  holds; its tree is left at its last shasums. The controller reads mtimes when
  it checks on seats and never waits on a silent one. Seats write a one-line
  progress note to their report file at least every 15 minutes, so silence is
  distinguishable from thought.
- **Talking to the owner:** <VOICE — lead with the outcome; one shape header per
  reply; plain language; present decisions as decided.>

## 5. The handoff law

The handoff is state only, on `HANDOFF_TEMPLATE.md`: where the world is, one
line per live tree, one line per landing, what is left in order, what only the
owner decides, the per-ticket numbers, and proposed amendments. It never
restates these laws (it points here) and never carries the history of what every
seat did — that is the ledger row the handoff line cites. It does not inherit
from the previous handoff; it supersedes it whole. The kickoff prompt is the
template's last section, filled in.
