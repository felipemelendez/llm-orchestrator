# THE LAWS — <PROJECT> (stable; read first every session; changed only by a numbered ruling from <OWNER>)

<!--
Template for `docs/llm-orchestrator/LAWS.md`. Fill every `<PLACEHOLDER>`, delete
this comment, and delete any section the project genuinely has no content for —
but not the harm ranking, which reviewers use to grade findings.
A short filled-in example is `laws-example.md` beside this template. An
assistant may draft the text for each placeholder in conversation; the owner
decides what goes in and pastes it here. Projects initialized before the
proportional workflow keep the rulebook they already have.
-->

This file is the project's rulebook. It holds rules, not status: what we are
building, what we promise, what counts as harm, and the decisions already made.
Current work and open questions belong in the conversation or a handoff, never
here. An assistant that believes a rule is wrong says so in its handoff and
keeps working under the rule as written. Only the owner changes this file.

This file is what the cadence lock protects. It changes only by a numbered
ruling from the owner, in a commit whose message carries `Ruling <N>`. The owner
makes that commit with the cadence skill's `cadence-ruling.sh`, in their own
terminal; an assistant proposes the change and never runs it.

## 1. What we are building, and why

<MISSION — two or three sentences: what the project is, who uses it, what it
must never get wrong.>

**The promises — judge every line of work by them.**

<PROMISES — three to five short lines.>

**Harm ranking.** Reviewers grade every finding into one of these three classes.
A catastrophic or serious finding must be fixed before the work is called done;
mild findings are fixed when convenient.

- Catastrophic: <the worst things this project can do to a user, plus: a claim
  that checks passed when they did not.>
- Serious: <wrong behavior that blocks or misleads a user, crashes, a test that
  passes without testing anything.>
- Mild: <wording, style, documentation and maintainability issues with no user
  consequence.>

## 2. The laws and rulings — never re-ask

- **Standing orders:** <the owner's own instructions, quoted word for word, that
  bind every session whatever the task is — for example never commit or push
  unless asked, never deploy, which files only the owner edits.>
- **Rulings that govern the build:** one line each, newest last, in this shape:
  `Ruling <N> (YYYY-MM-DD, <OWNER>): <one sentence>`. Numbering starts at one
  and only rises. The first ruling is the setup itself: record it here. The
  setup commit needs no ruling number in its message, because there is no
  earlier rule it amends. For every later policy change: pick the next number,
  add its line here, re-record the lock, and put `Ruling <N>` with that number
  in the commit message. The check script reads the highest number in this file
  and refuses a commit whose ruling is not higher than the last committed one.
- **Standing constraints:** <what must never happen without the owner — for
  example never `git add -A`, which trees are never deleted, which files
  another session may be editing.>
- **Hubs:** <the few files whose change touches everything. A change touching
  two of them is split into two changes.>

## 3. Reviewer models

Every time the assistant starts another agent, it names the model. Full work
has two independent reviewers with different instructions: one checks the change
against the spec, the other reads the user scenario and this harm ranking and
looks for the weakest point. Neither sees the other's findings first.
<OPTIONAL MODEL REQUIREMENTS — for example a required reviewer model or
provider; delete this line if the project has none. Different models for the
two reviewers are optional unless stated here.>

## 4. The standard of work

- **Workflow:** `workflow: proportional`. The assistant chooses Simple, Standard
  or Full by risk, uncertainty and how hard the change is to undo, following the
  `cadence` skill. Simple: make the change, read the whole diff, run the
  relevant existing checks, deliver. Standard: state what "done" means, then one
  independent review. Full: a reviewed design, two independent reviews, fixes,
  and verification by someone other than the writer. The person who wrote a
  change never supplies its required review.
- **Checks:** <the test, lint and type-check commands for this project, and
  when the full suite is required — for example only for hub changes.>
- **Completion:** every reply ends with `Verification: PASS | PENDING | BLOCKED
  | NOT APPLICABLE — reason`. PASS only when the recorded checks ran on the
  final code. <STRICTER RULE if any — for example "every code change needs a
  passing automated test"; otherwise NOT APPLICABLE is allowed for low-risk
  work with no meaningful automated check.>
- **Cleanup:** temporary reviews, logs and copies live outside the repository
  and are removed when the task finishes. Specs, research conclusions, design
  decisions and runbooks are kept.
- **Talking to the owner:** <VOICE — for example lead with the result, plain
  words, say clearly what is finished and what is not.>

## 5. The handoff

A handoff says where things stand, what was verified and by which checks, what
is left in order, what only the owner decides, and any proposed amendment to
these laws. It points at this file instead of repeating it, and it lives outside
Git unless the owner asks for a maintained document.
