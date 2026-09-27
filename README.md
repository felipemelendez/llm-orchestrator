# LLM Orchestrator

[![License](https://img.shields.io/github/license/felipemelendez/llm-orchestrator?color=blue)](./LICENSE) [![Last commit](https://img.shields.io/github/last-commit/felipemelendez/llm-orchestrator)](https://github.com/felipemelendez/llm-orchestrator/commits/main) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)

**Plan it, build it, review it, and check it.**

LLM Orchestrator is a plugin for Claude Code, with a smaller part for Codex. It helps the assistant turn an idea into a saved plan, build it task by task, have the change reviewed by independent reviewers, and run the tests before it says the work is done. When the assistant says `Verification: PASS` and no test ran, a hook tells the assistant so.

**New in 0.12.0:** lighter by default, a completion check that recognises real test commands, one review built on `/code-review` and `codex review`, rule changes through one command you run, and a Codex plugin. [What changed](./CHANGELOG.md) · [How to update](./docs/install.md#update).

## Quick Start

**Requirements:** Claude Code, Bash, Git and Python 3. The visual brainstorming panel also needs Node.js.

### Install on Claude Code

Run these one at a time inside Claude Code:

```text
/plugin marketplace add felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code. Type `/llm-orchestrator:` and the plugin's commands should appear in the menu.

### Install on Codex

In your terminal, clone the repository into a folder you will keep, then:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
codex plugin marketplace add "$PWD"
codex plugin add llm-orchestrator@llm-orchestrator
./scripts/install.sh --codex
```

Open a new Codex session, run `/hooks`, and trust the three hooks. Codex runs only hooks you have trusted. What Codex gets, and what it does not: [Codex](./docs/codex.md).

### First use

1. On an existing project, run `/llm-orchestrator:onboard` once. The assistant studies the code and, with your approval, writes the project's main decisions and conventions into `CLAUDE.md`.
2. Ask for what you want, in plain words. For a feature, the assistant asks a few questions, saves a spec, turns it into a plan (`/llm-orchestrator:plan`), builds it, has it reviewed (`/llm-orchestrator:review`) and runs the tests (`/llm-orchestrator:verify`).
3. To work from a plan you already have, say so: "Implement the plan in `docs/feature-plan.md` and report the review and test results."

Every command, with what it does: [commands guide](./docs/commands-guide.md). A worked example: [walkthrough](./examples/walkthrough.md).

## What happens by default

Out of the box the plugin stays quiet and adds these things:

- **Skills load when a task needs them.** Planning, debugging, test-first work and review each have a skill. Questions and small edits need none.
- **A completion check.** When a reply says `Verification: PASS` and no test ran and passed in that turn, a hook sends the assistant a note saying so. You see nothing, and it never blocks.
- **Two guards.** On the shared checkout, git commands that would throw away uncommitted work (such as `git reset --hard` or `git stash`) are refused, and so is skipping git's own hooks or commit signing (`--no-verify` and similar).
- **Two short notes, only when they apply.** Asking about a library, version or security topic while designing something adds a reminder to check current docs first. Near a full context window, the assistant is reminded once to write a handoff note.
- **Nothing leaves your machine.** Usage telemetry is off unless you turn it on.

Every hook, profile and switch: [Settings](./docs/install.md#settings).

## The cadence (optional, per project)

The cadence is a set of project rules that matches the amount of checking to the risk of a change. You turn it on per project with `/llm-orchestrator:cadence-init`; projects that do not run it are unaffected.

Before changing code or tests, the assistant reads the project's rulebook (`docs/llm-orchestrator/LAWS.md`) and picks a path:

- **Simple** — a small change that is easy to undo. Make it, read the diff, run the tests.
- **Standard** — a change in behaviour with real edge cases. Adds one independent review.
- **Full** — a change that touches several systems, is hard to undo, or changes how checks or security work. Adds a reviewed spec, two independent reviews (`/code-review` and `codex review`; with only one of them installed, it runs twice), fixes, and a final check by someone other than the writer.

At the end the assistant reports `PASS` only when the project's checks ran and passed on the final code; otherwise `PENDING`, `BLOCKED`, or `NOT APPLICABLE` with what it inspected instead.

The rulebook and config are protected by a lock with two layers: Claude Code deny rules stop the assistant editing them, and a git hook refuses a commit that changes them without a numbered ruling from you. Setup, changing the rules and what the lock cannot stop: [Enable cadence in a project](./docs/install.md#enable-cadence-in-a-project). What the design rests on, with sources: [docs/cadence-evidence.md](./docs/cadence-evidence.md).

## Is it right for you?

It spends more tokens to get a result you can trust: plans, fresh reviewers and real test runs cost more than a single prompt. Use it for multi-step features, refactors across files, debugging that needs investigation first, and work you want to hand off. For one-line fixes, it adds little.

Claude Code already has plan mode, `/code-review`, worktrees and memory. The plugin uses them where they do the job and adds the rules around them: when a step is required, what counts as proof, and in what order steps run. The full comparison: [What Claude Code does and what this adds](./docs/anthropic-ecosystem.md).

## Where to go next

- [Install, update and settings](./docs/install.md) — other install methods, the cadence setup, every setting.
- [Codex](./docs/codex.md) and [reviews from Codex](./docs/codex-provider.md).
- [Architecture](./ARCHITECTURE.md) — how it works, for contributors.
- [Measurements](./docs/MEASUREMENTS.md) — what has been measured, including what did not help.
- [Contributing](./CONTRIBUTING.md), [skills guide](./docs/skills-guide.md), [manual testing](./docs/manual-testing.md).

## License

MIT. See [`LICENSE`](./LICENSE).
