---
name: writing-skills
description: Use when adding a new skill or editing an existing one. Keeps the catalog short, the frontmatter correct, and the body free of coercion and padding.
---

# Writing skills

How to add a skill that fits LLM Orchestrator's bar.

## Before you write

Check that an existing skill doesn't already cover the trigger:

```
grep -l 'description:' skills/*/SKILL.md | xargs grep -h 'description:'
```

If something already triggers on this case, edit it. Don't add a near-duplicate.

## File shape

```
skills/<name>/SKILL.md
```

One directory, one file. Optional siblings (helper scripts, prompt fragments) live alongside.

## Frontmatter (two keys)

```yaml
---
name: <name>
description: Use when <trigger>. <Optional second sentence on scope.>
---
```

Rules the linter enforces:
- `name` must equal the directory name.
- `description` must start with `Use when`.
- The whole file must be ≤ 250 lines (target ≤ 150).

## Body conventions

Required sections in order:
1. **One-line purpose** at the top (no header).
2. **When to use** — bullets.
3. **When NOT to use** — bullets. Omit only if there's no plausible mis-trigger.
4. **Steps** — numbered.
5. **Output shape** — show the Concise Agent Protocol block this skill produces.
6. **Anti-patterns** — bullets, short.

Optional: a small table when comparing options.

## Voice

- Plain prose. No ALL CAPS. No "MUST", "ALWAYS", "NEVER" as the dominant register.
- No rationalization tables. Trust the reader to follow steps.
- No graphviz `dot` blocks. A numbered list communicates the same shape.
- One short sentence per bullet.
- Concrete file/line refs over abstract nouns.

## TDD for skills

Before you ship a skill, test it on a real subagent:

1. Write the skill body.
2. Construct a prompt that should trigger it (paste the user's likely message).
3. Dispatch a subagent with no context other than the skill file.
4. Did the subagent follow the steps? Produce the right shape?
5. If not, the skill is wrong — fix it. Don't add words to the prompt to compensate.

When the subagent succeeds without coaching, the skill is ready.

## Output shape

```
Changed:
- skills/<name>/SKILL.md — new skill
Verify:
- ./tests/validate-skills.sh → OK
- subagent with this skill produces the right shape on <example>
```

## Anti-patterns

- Skills that duplicate another skill 90%.
- Skills that exist to enforce one rule (make it a hook or a lint instead).
- Skills with paragraphs instead of bullets.
- Skills that grow past 200 lines (split or trim).
- Description fields that summarize the body instead of stating triggers.
