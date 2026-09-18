# v0.9.0 — the process matches the size of the change

v0.8.0 ran every code change through the full review sequence. That was too
much for small fixes. Now the assistant picks one of three paths by risk, never
by line count:

- **Simple** — a small, local, easily reversible change. Make it, read the
  whole diff, run the relevant tests, done. No extra agents.
- **Standard** — a bounded change with real edge cases. State what "done"
  means, make the change, run focused tests, get one independent review.
- **Full** — anything touching several systems, hard to undo, or changing how
  verification or security works. Reviewed design, two independent reviewers,
  fixes, and verification by someone other than the writer.

## Three more things changed

- **Tests are remembered.** A passing test stays valid while the files it
  covered are unchanged, so nothing is rerun just to look busy.
- **Claims are checked against what ran.** The assistant may say the work
  passed only when the recorded checks ran on the final code and cover every
  file it changed. Otherwise it says exactly what is still pending. A reply
  that changed nothing is never blocked, and the check's messages are one short
  line.
- **Temporary files clean themselves up.** Review copies and logs live outside
  your repository and are removed when the task finishes. Unfinished work is
  never deleted.

This works the same in Claude Code and Codex, from the same code.

## Getting started is simpler

Onboarding was rewritten for a first-time reader: a step-by-step guide,
[Enable cadence in a project](install.md#enable-cadence-in-a-project), a
plain-language rulebook template, and a filled-in example rulebook the
assistant can help you adapt. Projects set up with v0.8.0 keep the earlier
fixed sequence until you migrate them on purpose.

## Install or update

**Claude Code:** in your terminal, `claude plugin marketplace update llm-orchestrator`
then `claude plugin update llm-orchestrator@llm-orchestrator`, and restart the
session. Run `/llm-orchestrator:cadence-init` in a project that has not enabled
cadence yet.

**Codex:** in your framework checkout, `git pull --ff-only` then
`./scripts/install.sh --codex`. Open a fresh Codex session and check `/hooks`.

[Full changelog](../CHANGELOG.md) · [Installation and update guide](install.md#updating-to-v090)

## What was checked

The change was reviewed independently by Codex and by Claude, several times,
and every problem they found was fixed or written down as a known limit. The
complete test suite passed, and the framework now runs its own process on
itself: its live checks accepted the final version in a fresh session.

## Known limits

Codex does not report where a shell command ran or whether it finished, so
shell writes there cannot be confirmed; use the file-edit tool. A command the
tool moves to the background is never seen finishing; give long test runs a
longer time limit. Files Git ignores are outside what the checks can see; keep
generated files out of the source the tests must cover.
