# THE LAWS — Ledgerly (stable; read first every session; changed only by a numbered ruling from Ana)

<!--
A filled-in example of `docs/llm-orchestrator/LAWS.md` for a small, made-up
project, kept short on purpose. Copy the shape, not the content: your laws
should say what is true for your project. The template with placeholders is
`laws.md` beside this file.
-->

This file is the project's rulebook. It holds rules, not status: what we are
making, what we promise, what counts as harm, and the decisions already made.
Current work and open questions go in the conversation or a handoff, not here.
If an assistant thinks a rule is wrong, it says so in its handoff and keeps
following the rule. Only Ana changes this file.

This file is what the cadence lock protects. It changes only by a numbered
ruling from Ana, in a commit whose message carries `Ruling <N>`. Ana makes that
commit with the cadence skill's `cadence-ruling.sh`, in her own terminal; an
assistant proposes the change and never runs it.

## 1. What we are building, and why

Ledgerly is a web app where freelancers record invoices and see what is still
unpaid. Users trust it with money figures; losing or miscounting one is the
worst thing it can do.

**The promises — judge every line of work by them.**

- No invoice is ever lost, duplicated or silently changed.
- Every total shown to a user is computed from the stored invoices, never
  cached separately.
- Nothing is called done without a passing test run on the final code.

**Harm ranking.** Reviewers grade every finding into one of these three classes.
A catastrophic or serious finding must be fixed before the work is called done;
mild findings are fixed when convenient.

- Catastrophic: lost or duplicated invoices; a wrong total; another user's
  data shown; a claim that tests passed when they did not.
- Serious: a page that crashes or blocks a common action; a slowdown that
  makes the app unusable; a test that passes without testing anything.
- Mild: wording, layout, code style and documentation issues with no user
  consequence.

## 2. The laws and rulings — never re-ask

- **Standing orders:** never commit or push unless Ana asks in that turn;
  never run database migrations against anything but the local database;
  Ana deploys, assistants never do.
- **Rulings that govern the build:**
  `Ruling <N> (2026-09-18, Ana): adopt the proportional workflow; Simple for local reversible changes, Standard for bounded behavior changes, Full for anything touching billing totals or authentication.`
  In a real rulebook `<N>` is a number. This first ruling is number one; the
  setup commit itself needs no ruling number. Each later ruling takes the next
  number, and its commit message carries that number.
- **Standing constraints:** the `migrations/` folder is Ana's; propose a
  migration as text instead of writing it. Never delete another session's
  branch or worktree.
- **Hubs:** `src/billing/totals.ts` and `src/auth/session.ts`. A change that
  touches both is split into two changes.

## 3. Reviewer models

Every time the assistant starts another agent, it names the model. Reviews run
on the strongest available model; the two reviewers on Full work get different
instructions, one written from the spec and one written in plain language with
the harm ranking, and neither sees the other's findings first. Ledgerly does
not require different models for the two reviewers.

## 4. The standard of work

- **Workflow:** `workflow: proportional`. Simple means edit, read the whole
  diff, run the relevant tests, deliver. Standard adds acceptance criteria and
  one independent review. Full follows the cadence skill's Full path. The
  person who wrote a change never supplies its required review.
- **Checks:** `npm test` for the affected area with two workers; `npm run
  typecheck` after any TypeScript change. Full suites only for hub changes.
- **Completion:** end every reply with `Verification: PASS | PENDING | BLOCKED |
  NOT APPLICABLE — reason`. PASS only when the checks ran on the final code.
  Ledgerly is deliberately stricter than the skill's default: every completed
  code change needs a passing automated test, so NOT APPLICABLE is reserved for
  documentation and configuration text.
- **Cleanup:** temporary reviews and copies live outside the repository and
  are removed when the task finishes; keep specs and design notes.
- **Talking to Ana:** lead with the result, plain words, say clearly what is
  finished and what is not.

## 5. The handoff

A handoff says where things stand, what was verified and how, what is left in
order, and what only Ana decides. It points at this file instead of repeating
it.
