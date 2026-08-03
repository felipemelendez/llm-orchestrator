# Scaffolding this plugin may no longer need

Date: 2026-08-03 · Status: **recommendations, not applied** — each is a behavior change to a system
the owner uses daily, and none is covered by the review of the current diff.

## Why this list exists

Anthropic's current published position cuts against adding scaffolding for the Claude 5 generation,
and in several places against keeping what already exists. Re-fetched verbatim from
[The new rules of context engineering for Claude 5 generation models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)
(2026-07-24):

> We removed over 80% of Claude Code's system prompt for models like Claude Opus 5 and Claude
> Fable 5 with no measurable loss on our coding evaluations.

> We found that we were overconstraining Claude Code, both through our system prompt and in our
> CLAUDE.md files and skills.

Six shifts are listed; two bear directly on this plugin — **"Give Claude rules" → "Let Claude use
judgement"** and **"Repeat yourself" → "Simple tool descriptions"**. Alongside that, the migration
guide tells Opus 5 users to *delete* verification scaffolding ("instructions like these cause
over-verification… removing them reduces wasted tokens with no loss in quality"), and the Fable 5
page warns that skills tuned for earlier models "are often too prescriptive… and can degrade output
quality".

The counter-evidence matters too, and it is why this is a list rather than a patch. obra/superpowers
ran the same compression sweep in mid-2026 and **reversed one cut after measuring it**: deleting the
TDD skill's "Why Order Matters" rebuttals dropped test-first behavior under pressure from 8/10 to
5/10, so the content was folded into rationalization rows instead of removed. Their rule — cut
persuasion padding, keep load-bearing counter-rationalization, and *measure each cut* — is the right
one here. None of the candidates below has been measured on this repo.

## Candidate 1 — the per-turn protocol reminder duplicates the SessionStart core

**This is the strongest candidate.** Measured on this tree:

```
SessionStart eager block   2534 chars (~633 tokens)  once per session
Per-turn reminder           613 chars (~153 tokens)  EVERY turn
```

Every shape header (`Changed:` `Found:` `Blocked:` `Issues:` `Plan:` `Status:`), the `Verify:`
requirement, `file:line`, and "no preamble" appear in **both**. The per-turn injection
(`scripts/hooks/user-prompt-submit.sh`) restates what SessionStart already established, which is
precisely the "repeat yourself" pattern the July 2026 post says to stop — its concrete example is
guidance duplicated across the system prompt and tool descriptions.

Cost: ~153 tokens × every turn, forever. On a 200-turn session that is ~30K tokens spent restating
a rule the model was already given.

Recommendation: drop the reminder to the part that is *not* in the SessionStart core (the skill
precedence ordering), or remove it entirely and measure whether protocol conformance changes. The
protocol grader already measures conformance mechanically, so this one is cheap to test honestly:
run N turns with and without, count grader warnings.

Do not delete it blind. `README.md:72-96` stakes the plugin's whole counter-position on "how much of
the system still works on the turns the model ignores its instructions" — and that position is
currently *unmeasured*, which is the real problem.

## Candidate 2 — instruction-priority and "the rule" sections restate each other

`skills/using-orchestrator/SKILL.md` states "invoke relevant skills before responding" in the eager
block (line 13), again under `## The rule` (line 41), and the same idea appears a third time in the
per-turn reminder. Three statements of one rule is the shape the post names.

## Candidate 3 — `Response detail` prescribes what judgment now handles

`### Required sub-sections` and `### Working rules` enumerate formatting rules ("one sentence per
bullet", "no 'Sure!', 'Of course', 'Great question'"). The post's replacement pattern is to give the
reason rather than the rule, on the grounds that the model generalizes from an explanation. A single
sentence of intent likely does the work of the list.

## What should NOT be deleted

- **The two PreToolUse guards.** These are not model-behavior scaffolding; they are data-loss
  backstops that operate on the tool call regardless of what the model intended. The guidance about
  over-constraining prompts has no bearing on them.
- **The evidence ledger and verify gate.** Same reason: the ledger is written by a hook and read by
  a hook, with the model outside the loop. This is the "deterministic structure for the
  control/verification loop, model judgment for content" split Anthropic's own harness posts
  recommend.
- **The two-stage review.** Fresh-context review is the one multi-agent boundary current guidance
  still endorses; see `2026-08-03-workflow-scope-decision.md`.
- **`Done when:` / `Stop if:` termination contracts.** These are task specification, not
  anti-laziness prompting.

## The honest bottom line

The plugin's defensible thesis is that hooks enforce what prose cannot — and every item in "what
should NOT be deleted" is a hook. The items in the candidate list are all *prose*, and prose is
exactly what Anthropic reports being able to delete. That asymmetry is the finding: this system's
mechanical half has aged well and its instructional half is carrying weight it may no longer need.

Nothing here should be changed without a measurement, because the one time someone in this
ecosystem measured a compression cut, it was wrong 1 time in 8.
