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

Rules the linter (`tests/validate-skills.sh`) enforces:
- `name` must equal the directory name.
- `description` must start with `Use when`.
- The whole file must be ≤ 250 lines (target ≤ 150).

## Body conventions

Nothing below the frontmatter is machine-checked, and no fixed section list is
required — a previous version of this file mandated five sections in order that
no skill in the corpus (including this one) satisfied. The working skeleton,
used where each part earns its place:

- **One-line purpose** at the top (no header) — near-universal; keep it.
- **When to use / when not to** — include when the trigger has a plausible
  mis-fire; the frontmatter `description` already carries the primary trigger.
- **Steps** — numbered, when the skill is a procedure rather than a reference.
- **Output shape** — the Concise Agent Protocol block the skill produces, when
  it produces one.
- **Anti-patterns** — short bullets; the most consistently useful section in
  practice.

A small table is fine when comparing options.

## Voice

- Plain prose. No ALL CAPS. No "MUST", "ALWAYS", "NEVER" as the dominant register.
- No rationalization tables. Trust the reader to follow steps.
- No graphviz `dot` blocks. A numbered list communicates the same shape.
- One short sentence per bullet.
- Concrete file/line refs over abstract nouns.

## Match the form to the failure

The shape of the guidance should match the shape of the thing going wrong.

| The failure | The form that fixes it |
|---|---|
| A rule gets skipped under pressure | A prohibition |
| The output has the wrong shape | A positive recipe: what the output **is**, and its parts in order |
| A required element gets omitted | A structural slot in a template they fill in |
| Behaviour should depend on context | A conditional keyed to something observable |

Row two is the one that gets written wrong. Told "don't do X", a model produces
measurably *more* X than one given a recipe for the right shape — and in
measurement, worse than no guidance at all. If you catch yourself writing a
prohibition about output shape, write the recipe instead.

Two authoring rules that follow:

- **No nuance clauses.** "Don't do X unless it matters" reopens the negotiation
  you just closed. A single hedge appended to a working recipe degrades it from
  consistent to noisy.
- **Exemption clauses do not scope.** "This limit does not apply to code blocks"
  still suppresses code blocks. If part of the output must be exempt, restructure
  so the rule cannot reach it.

## Testing a skill

Write the body, then test it the way you would test code — but the first run is
the control, not the skill.

Run a **no-guidance control first.** Give a fresh agent the realistic task
without the skill. If the failure you are writing against does not appear, there
is nothing to fix — stop, and do not author the guidance. Most over-instruction
starts here.

If it does appear: five or more fresh-context runs per variant, the guidance in
its real host context, and read every flagged result by hand — a template echo
looks exactly like a hit until you read it.

**Variance is the metric.** Five different interpretations across five runs
means the wording is not binding. Tighten the form; do not add words.

When a skill fails in real use, ask the agent that failed how it should have
been written. Three answers, three different fixes:

- "It was clear, I chose not to follow it" — not a documentation problem.
- "It should have said X" — add X verbatim.
- "I did not see that section" — an organisation problem; move it earlier.

## Cross-references

Link with a relative markdown path, never `@`. The `@` form force-loads the file
immediately, spending context before anything needs it.

Keep references one level deep. Agents preview a nested reference with something
like `head -100` and act on a partial read. A reference file over 100 lines
carries a table of contents.

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
- Skills that grow past 250 lines (split or trim; target 150).
- Description fields that summarize the body instead of stating triggers.
