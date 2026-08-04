---
name: writing-skills
description: Use when adding a new skill or editing an existing one. Not for commands (commands/*.md) or agent definitions.
---

# Writing skills

House style for `skills/<name>/SKILL.md`. One test governs every line: would a
capable model get this wrong without it? Anthropic cut over 80% of Claude
Code's system prompt "with no measurable loss", and skills written for prior
models "are often too prescriptive for Claude Fable 5 and can degrade output
quality". State the opinion, contract, or fact the model cannot infer; let it
judge the rest.

## Before you write

Check nothing already triggers on this case — edit the near-match instead of
adding a sibling:

```
grep -h 'description:' skills/*/SKILL.md
```

A skill earns a directory when it carries a procedure or a house opinion; a
single rule belongs in a hook or the linter.

## Frontmatter

```yaml
---
name: <directory name>
description: Use when <trigger>. Not for <adjacent non-trigger>.
---
```

Two keys. The description is triggers only — the situations and keywords an
agent would match — never a workflow summary. Measured: a description saying
"code review between tasks" made agents run one review when the body specified
two; they followed the description and skipped the body.

## Body budget

A loaded body stays in context for the rest of the session — every line is a
recurring token cost.

- Default skill: about 500 words.
- Skill loaded in most sessions: about 200.
- Hard cap (linted): 250 lines; target 150.

The budget cuts narration — coercion, recap, justification, examples of things
the model already does right. It never cuts facts: a skill that encodes an API
contract is done when each fact is stated once, plainly, and deleting a fact to
hit a word count is a bug. If facts alone exceed the budget, move reference
material to a sibling file and link it.

## Steps vs judgment

Number steps only when the order is the content (red before green; take the
lock before writing). Otherwise state the goal and the constraints and let the
model sequence the work — a step list is followed literally, including when it
does not fit the case at hand.

## Rationale: one clause, aimed at pressure

Two measured results pull opposite ways:

- "State what to do rather than narrating how or why" — narration is the bulk
  of every over-budget body.
- Deleting the TDD skill's why-order-matters rationale dropped test-first
  behavior from 8/10 to 5/10 under "just write it, tests after" pressure. The
  rationale was the counterargument the agent needed mid-rationalization.

The line between them: rationale is load-bearing when the rule fights an
incentive the agent will feel while working — keep it, one clause, next to the
rule it defends. Rationale for a rule nothing tempts the agent to break is
padding — cut it.

## Match the form to the failure

| Failure | Form |
|---|---|
| Rule gets skipped under pressure | Prohibition, with its defending rationale |
| Output has the wrong shape | Positive recipe: what the output is, parts in order |
| Required element gets omitted | A template slot to fill |
| Behavior depends on context | Conditional keyed to something observable |

Prohibitions suit discipline failures only. Aimed at output shape they
measurably backfire: in wording tests the prohibition arm produced more of the
unwanted content than the recipe arm, trending worse than no guidance at all.

- No nuance clauses. "Don't X unless it matters" reopens the negotiation; one
  appended hedge degraded a winning recipe from consistent to noisy. A real
  exception is its own conditional on an observable predicate.
- Exemption clauses don't scope — "does not apply to code blocks" still
  suppresses code blocks. Restructure so the rule cannot reach the exempt part.

## Voice

Plain prose, one short sentence per bullet. No all-caps register, no
rationalization tables, no graphviz. Concrete file refs over abstract nouns.

## Test against a control

Run the realistic task without the skill first. If the failure never appears,
stop — there is nothing to author; most over-instruction starts here. If it
does: five fresh-context runs per wording, every flagged result read by hand.
Variance is the metric — five interpretations across five runs means the
wording is not binding; tighten the form, don't add words.

When a deployed skill fails, ask the failing agent what the file should have
said. "I chose not to follow it" — not a documentation problem. "It should
have said X" — add X verbatim. "I didn't see that section" — move it earlier.

## Cross-references

Relative markdown links, never `@` — the `@` form force-loads the file before
anything needs it. One level deep; a reference file over 100 lines carries a
table of contents, because agents preview with `head -100` and act on partial
reads.

## Output shape

```
Changed:
- skills/<name>/SKILL.md — <what changed>
Verify:
- ./tests/validate-skills.sh → OK
- no-guidance control showed the failure; skilled runs converge on one shape
```
