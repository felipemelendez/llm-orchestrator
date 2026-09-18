# v0.8.0 — plan in Claude Code, build with Claude Code or Codex

**I prefer to brainstorm and plan with Claude Code, then build with both Claude
Code and Codex.** This release brings that workflow to LLM Orchestrator: save an
agreed plan, then use either assistant to implement it, review the changes, and
check the results.

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

## Why the full plugin stays in Claude Code

The Claude Code plugin includes brainstorming, research, and planning because
that is where I prefer to do that work. The Codex setup focuses on what comes
next: implementing the approved plan, getting independent reviews, and verifying
the result. The shared development process is available in both tools, so you
can choose which one to use for the implementation.

## How to use the workflow

1. **Plan in Claude Code.** Explore the idea and save the approved plan in your
   project.
2. **Build with either tool.** Continue in Claude Code, or open the project in
   Codex and point it to the saved plan.
3. **Review and verify.** Both follow the project's cadence: the agreed steps for
   implementation, independent reviews, fixes, and testing.

## What is new

- **Two independent reviews.** One checks the changes against your request; the
  other looks for ways they could fail. They work separately, without seeing
  each other's reports.
- **Extra review only where needed.** If both agree on the findings, their
  seriousness, and the next steps, the process moves on. A third agent examines disagreements or a serious
  problem raised by only one reviewer. An unfinished review must be completed.
- **Recorded test results in Codex.** Automatic checks record what actually ran
  and which version of the code was tested. Missing, failed, or out-of-date
  results stay unverified.
- **Project rules stay with the project.** Enable cadence where you want it.
  Your rules, test commands, and review records stay in that repository.

## Install or update

**Claude Code:** install or update the plugin and restart the session. Run
`/llm-orchestrator:cadence-init` to set up a project that has not enabled cadence.

**Codex:** run `./scripts/install.sh --codex` from your framework checkout. Open a
fresh Codex CLI session, review and trust the automatic checks through `/hooks`,
and enable cadence and Codex verification in the project. Rerun the installer
after updating the framework.

[Follow the installation and update guide](https://github.com/felipemelendez/llm-orchestrator/blob/main/docs/install.md)
for the commands and an explanation of what each step does.

## What was checked

The implementation received independent reviews, the issues found were fixed,
and the merged version passed the automated tests. A fresh Codex CLI session also
confirmed that test results and review activity were recorded and that the final
completion check passed. Checks on a running app or device still need their own
verification.

[Full changelog](https://github.com/felipemelendez/llm-orchestrator/blob/main/CHANGELOG.md)
· [Changes since v0.7.0](https://github.com/felipemelendez/llm-orchestrator/compare/v0.7.0...v0.8.0)
