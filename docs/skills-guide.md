# Skills guide

How LLM Orchestrator skills are shaped, and how to write a new one.

## Anatomy

```
skills/<name>/SKILL.md
```

One directory, one file. Optional sibling files (prompt fragments, scripts) live next to it.

## Frontmatter

Required:
- `name` — hyphenated, lowercase, matches the directory name.
- `description` — triggers only, not a workflow summary. Two sentences max. Starts with "Use when".

Optional:
- `tools` — comma-separated list of tools the skill needs.
- `profile` — `minimal | standard | strict`. Restricts when the skill is loadable.

Example:

```yaml
---
name: writing-plans
description: Use when a spec is approved and you need a step-by-step implementation plan. Produces a dated, checklist-shaped plan file.
---
```

## Body conventions

- Markdown. Sections in order: Purpose (one line at top), When to use, Steps, Output shape, Anti-patterns.
- Sentences, not paragraphs.
- Tables when comparing options.
- Code blocks for response shapes and commands.
- Length target: under 200 lines. If it's longer, the skill is doing too much.

## Description rule (the one that matters)

The `description` field must describe **triggers**, not workflow. The harness uses this field to decide whether to invoke the skill. If you summarize the workflow there, the model thinks it has the gist and skips the body.

Good:
> Use when a diff is ready for review — before merge, before PR, before claiming a feature is done.

Bad:
> Reviews code by checking files in order, scoring issues, and reporting in markdown.

## Voice

- No ALL CAPS.
- No "MUST", "ALWAYS", "NEVER" as the dominant register. Strong words once, plain prose elsewhere.
- No rationalization tables or "red flags" sections. Trust the reader.
- No Graphviz `dot` charts; if a decision is non-obvious, a numbered list works.

## Output shape

Every skill ends with a "Output shape" section showing the Concise Agent Protocol block the agent should produce. This is what makes skills compose.

## Adding a skill

```
mkdir skills/<name>
cp templates/skill.md skills/<name>/SKILL.md
$EDITOR skills/<name>/SKILL.md
./tests/validate-skills.sh
```

The validator checks:
- Directory name matches `name:` in frontmatter.
- `description:` starts with "Use when".
- File is ≤ 250 lines.
- No 4+ consecutive ALL CAPS words outside code blocks.

For a deeper walkthrough including TDD-for-skills, see the `writing-skills` skill itself.

## When NOT to add a skill

- The behavior is already covered by an existing skill.
- The behavior is a single command (it's a slash command, not a skill).
- You're tempted to write 800+ words. Reconsider the scope.
