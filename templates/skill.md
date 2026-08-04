---
name: <directory name>
description: Use when <trigger>. Not for <adjacent non-trigger>.
---

<!--
Scaffold for skills/<name>/SKILL.md. Read skills/writing-skills/SKILL.md first —
this file is that skill's shape, not a substitute for it.

There are no required sections. This scaffold used to mandate five
(When to use / When NOT to use / Steps / Output shape / Anti-patterns) and kept
regenerating them for months after the catalogue had moved off that form, because
CONTRIBUTING.md and docs/skills-guide.md both start a new skill by copying this
file. Use whichever headings the content needs.

Governing test for every line: would a capable model get this wrong without it?
Anthropic cut over 80% of Claude Code's system prompt with no measurable loss,
and skills written for earlier models are often too prescriptive for the current
generation and degrade output. State the opinion, contract, or fact the model
cannot infer; let it judge the rest.

Budget: ~500 words of body (~200 if the skill loads in most sessions). Linted
hard cap 250 lines, target 150, plus a per-skill word ceiling in
tests/validate-skills.sh that ratchets down. The budget cuts narration, never
facts — deleting a fact to hit a word count is a bug.

Number steps ONLY when the order is the content (red before green; take the lock
before writing). A step list is followed literally, including when it does not
fit the case at hand.

Keep one clause of rationale where — and only where — the rule fights an
incentive the agent will feel while working. That is measured, not stylistic:
deleting the TDD skill's why-order-matters clause dropped test-first behaviour
from 8/10 to 5/10 under "just write it, tests after" pressure, and this repo
reproduced it at 76/100 -> 56/100, Fisher p=0.004. Rationale for a rule nothing
tempts the agent to break is padding.

Match the form to the failure:
  rule skipped under pressure  -> prohibition + its defending rationale
  output has the wrong shape   -> positive recipe, parts in order
  required element omitted     -> a template slot to fill
  behaviour depends on context -> conditional keyed to something observable
Prohibitions aimed at output shape measurably backfire — the prohibition arm
produced MORE of the unwanted content than the recipe arm.

Delete this comment block before committing.
-->

# <Skill name>

One line: what this skill is for, in the situation its description triggers on.

<The content. Prose where the reasoning matters; a recipe or table where a shape
has to be reproduced exactly. Cite real paths — file:line beats an abstract noun.>

## Output shape

```
Changed:
- <file:line> — <what>
Verify:
- <cmd> → <the line it actually printed>
```

<!--
Before claiming it works: run the realistic task WITHOUT the skill. If the
failure never appears there is nothing to author — delete the file. Most
over-instruction starts here. If it does appear: five fresh-context runs per
wording, every flagged result read by hand. Variance is the metric — five
interpretations across five runs means the wording is not binding, so tighten
the form rather than adding words.

Verify: ./tests/validate-skills.sh → OK
-->
