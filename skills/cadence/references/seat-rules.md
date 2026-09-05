# Seat rules (pasted by reference into every dispatch)

<!--
Copy this into `<SCRATCH>` as `SEAT_RULES.md`, fill the placeholders once per
session, and name it in every seat's brief. The placeholders: `<SCRATCH>` the
evidence folder defined below, `<WORKTREE>` the tree a writing seat owns,
`<BASE_SHA>` the commit it is based on, `<TICKET>` the ticket id, `<MAIN>` the
checkout no seat may write in.
-->

`<SCRATCH>` is the project's `notes_dir` from `cadence.json` (default
`docs/llm-orchestrator/notes`), and it is flat: every `<TICKET>_*_report.md`
lands there directly, in that one folder, because that is where the landing
check looks for the evidence.

- **Spawn ceiling 0.** No subagents. Work only where your dispatch names.
  Read-only seats edit nothing outside `<SCRATCH>`, except probe paths they
  create under their own copy of the tree or under a `mktemp -d` and delete
  before reporting. Writing seats work only in `<WORKTREE>`; never in `<MAIN>`
  and never in any tree another seat owns.
- **git: lock-free reads only** — `git diff`, `git status --porcelain`,
  `git show`, `git log`. Never checkout, stash, commit, reset, add or push. The
  controller lands; a seat never does.
- **Stamps.** Your status block opens with `Started: <YYYY-MM-DD HH:MM:SS>` and
  closes with `Finished: <…>`, both from `date '+%Y-%m-%d %H:%M:%S'`. Write a
  one-line progress note into your report file at least every 15 minutes of
  work. A seat silent for 20 minutes is stopped and replaced.
- **Floors.** Run the project's verification unpiped, into a log, and read the
  counts from the log: `<test command> > <SCRATCH>/<TICKET>_<seat>.log 2>&1;
  echo EXIT=$?`. A command piped to `tail` reports `tail`'s exit status. Any
  suite the project marks as making paid API calls is never run.
- **Proof.** Every mutation is reverted and proven by `shasum` or `cmp`; list the
  shasums in the report. Anything you could not reach is marked `UNVERIFIED`,
  never silently omitted. A pin that passes with its mechanism removed is
  worthless: prove each new test red on the unfixed tree.
- **Reviewers** never read the implementer's report or the other seat's
  findings; they re-derive from the tree. Findings are neutral tickets: state →
  wrong output → rank (per the harm ranking in `LAWS.md`) → `EXECUTED` with the
  failing line, or `REASONED` with `file:symbol`. Every catastrophic or serious
  finding carries `SCENE: given <state>; when <action>; expect <observable>`. A
  longer report is not a better one.
- **Refuter seats:** the burden is on you to drop — cite the `file:line` that
  refutes. Doubt promotes.
- **Neutral vocabulary.** State → wrong output. No threat prose, no adjectives
  standing in for evidence.
- **One status block** at the end, `≤ 40 lines`, with the verdict your brief
  names. Write the report to `<SCRATCH>` with your seat's prefix and print it as
  your final message.
