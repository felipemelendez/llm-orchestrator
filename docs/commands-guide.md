# Commands guide

How LLM Orchestrator slash commands are shaped, and how to add one.

## Anatomy

```
commands/<name>.md
```

One file. Frontmatter (the YAML block at the top, between `---` markers) with `description`. Body is the prompt Claude Code sends when the user types `/<name>`.

## Frontmatter

```yaml
---
description: One-line summary of what the command does. Triggers, not workflow.
---
```

## Body conventions

- Tell the agent what role it's in: "You are running `/<name>`."
- Numbered steps, not paragraphs.
- Reference skills by name (the agent will invoke them).
- End with a `Constraints:` section listing what not to do.
- Show the expected output shape at the bottom.

## Composition: commands invoke skills

A command is a workflow wrapper. The skill is the discipline. Most commands open by invoking one skill, then call out to others as needed.

Example: `/llm-orchestrator:review` invokes `requesting-code-review`, which dispatches subagents for spec-compliance then code-quality, plus an optional third security pass when the diff touches security-sensitive code.

## When to add a command

- The user will type this often.
- It maps to a single, named user intent ("plan this", "review this").
- It composes 2+ skills into one entry point.

## When NOT to add a command

- It's a one-shot prompt the user can type themselves.
- It's a skill in disguise (just a discipline, not an action).

## Naming

- Lowercase, hyphenated. Match the file name to the command.
- Short. `/llm-orchestrator:plan`, not `/create-implementation-plan`.

## Adding a command

```
$EDITOR commands/<name>.md
./tests/validate-skills.sh    # validates frontmatter description on commands too
```

The validator checks the `description:` field on every command. Body validation (Constraints section, output shape) is not currently enforced.

## Built-in commands (v0.1)

| Command            | What it does                                                            |
|--------------------|--------------------------------------------------------------------------|
| `/llm-orchestrator:onboard`         | One-time codebase study: maps architecture and conventions, proposes `## Decisions` + `## Conventions` for `./CLAUDE.md`, writes them on a single approval. Idempotent — skips if already onboarded. Run this first on an existing project before any feature work. |
| `/llm-orchestrator:init`            | Add LLM Orchestrator conventions to a project.                          |
| `/llm-orchestrator:plan`            | Turn an approved spec into a checklist-shaped plan.                     |
| `/llm-orchestrator:worktree`        | Create an isolated git worktree.                                        |
| `/llm-orchestrator:dispatch`        | Run a focused subagent with a constructed context envelope.             |
| `/llm-orchestrator:review`          | Two-stage review (spec + code quality), plus an optional security pass on sensitive diffs. |
| `/llm-orchestrator:debug`           | Root-cause debugging.                                                   |
| `/llm-orchestrator:verify`          | Run tests/lint/typecheck and report evidence.                           |
| `/llm-orchestrator:finish`          | Decide between merge / PR / keep / discard.                             |
| `/llm-orchestrator:remember`        | Append a fact to project CLAUDE.md (or user CLAUDE.md / plugin research config), classified by section. |
| `/llm-orchestrator:forget`          | Soft-delete matching lines from CLAUDE.md or plugin memory.             |
