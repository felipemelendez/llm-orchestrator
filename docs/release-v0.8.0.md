# v0.8.0 — independent reviews for Claude Code and Codex

This release brings the shared review process to **Claude Code and Codex**. It
helps your assistant check its work, get an independent second opinion, and show
what actually passed before calling a change finished.

## Update, 2026-09-18: the process now matches the size of the change

The first version of this release ran every code change through the full
review sequence. That was too much for small fixes. Now the assistant picks
one of three paths by risk, never by line count:

- **Simple** — a small, local, easily reversible change. Make it, read the
  whole diff, run the relevant tests, done. No extra agents.
- **Standard** — a bounded change with real edge cases. State what "done"
  means, make the change, run focused tests, get one independent review.
- **Full** — anything touching several systems, hard to undo, or changing
  how verification or security works. Reviewed design, two independent
  reviewers, fixes, and verification by someone other than the writer.

Three more things changed:

- **Tests are remembered.** A passing test stays valid while the files it
  covered are unchanged, so nothing is rerun just to look busy.
- **Claims are checked against what ran.** The assistant may say the work
  passed only when the recorded checks ran on the final code and cover every
  file it changed. Otherwise it says exactly what is still pending.
- **Temporary files clean themselves up.** Review copies and logs live
  outside your repository and are removed when the task finishes. Unfinished
  work is never deleted.

Onboarding was rewritten for a first-time reader: a step-by-step guide,
[Enable cadence in a project](install.md#enable-cadence-in-a-project), a
plain-language rulebook template, and a filled-in example rulebook.
Existing projects keep the earlier fixed sequence until you migrate them.

## What changes for you

- **Two independent reviews.** One reviewer checks the work against your request;
  the other looks for ways it could fail. They review separately, without seeing
  each other's reports.
- **A third agent only when needed.** When both reviewers agree on the findings,
  their seriousness, and the next steps, the process moves on. When they disagree,
  or only one raises a serious problem, a third agent examines those findings.
  An unfinished review must be completed first.
- **Codex checks actual test results.** Automatic checks record what ran and which
  version of the code was tested. Missing, failed, or out-of-date results remain
  unverified. The assistant's written claim alone does not count as a passing test.
- **Your project keeps its rules.** Enable the process, called cadence, separately
  in each project. Its rules and test commands stay with that project, and checks
  flag unexpected changes to those rules.
- **Claude can review work from Codex.** The optional Claude reviewer uses your
  existing login and defaults to Opus at maximum effort. It fills one of the two
  review slots. Grok is not required.

This release adopts useful ideas from pstack: recording which assistant
actually performed a review and making app checks repeatable. LLM Orchestrator still coordinates
the work. App-specific test journeys stay in the app's repository; installing the
framework alone does not create or run them.

## Get started or update

**Claude Code:** install or update the Claude plugin, restart the session, and use
`/llm-orchestrator:cadence-init` in projects where you want cadence.

**Codex:** run `./scripts/install.sh --codex` from a permanent framework checkout.
Then open a fresh Codex CLI session, review and trust the definitions in `/hooks`,
and enable cadence and Codex verification in your project. Repeat the installer
after updating the checkout; existing copies do not update automatically.

[The installation guide](https://github.com/felipemelendez/llm-orchestrator/blob/v0.8.0/docs/install.md)
includes the commands, upgrade steps, and a plain-language explanation of hooks.
Claude Code and Codex share the cadence rules, while some additional checks remain
specific to Claude Code.

## What was checked

The changes were independently reviewed against the requirements and checked for
ways they could fail. The issues found were fixed and checked again. Automated tests cover the
installer, review provider, protected files, and verification records. A fresh
Codex CLI session also confirmed that test results were accepted, review activity
was recorded, and the final completion check passed.

These checks help catch mistakes; they do not prove every feature of your app
works. Checks on a running app or connected device still need to be performed
and reported separately.

[Full changelog](https://github.com/felipemelendez/llm-orchestrator/blob/v0.8.0/CHANGELOG.md)
· [Changes since v0.7.0](https://github.com/felipemelendez/llm-orchestrator/compare/v0.7.0...v0.8.0)
