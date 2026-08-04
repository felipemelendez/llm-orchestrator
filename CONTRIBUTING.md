# Contributing

How to add a skill, command, or subagent role: copy a template, run the tests, open a PR. Everything here is markdown + shell — no separate program to install (the "runtime" is the files themselves).

This is intentionally a small, opinionated kit:

- **Pure markdown + shell.** No build step. Add a skill by copying `templates/skill.md`. Hooks (automation scripts Claude Code runs at lifecycle events) live in `scripts/hooks/`.
- **Small catalog (18 skills).** Your contribution actually gets noticed and used. Past ~40 skills the catalog gets unscannable — we cap there on purpose.
- **Real test suite.** 33 suites, discovered rather than listed, run by `./tests/run-all.sh` in about three minutes and gating every commit. They catch regressions in JSON schemas, hook output formats, concurrency, portability (bash 3.2 / BSD / macOS), and shape-checking. Behavioural claims go further: `tests/evals/` A/B-tests the plugin against a bare model and against any earlier commit, with Fisher's exact test on the result.
- **TDD-for-skills loop documented.** `writing-skills` walks through: write a skill, dispatch a test subagent with no other context, see if the subagent follows the skill, refine.
- **Native Claude Code primitives.** Your contribution works for everyone who uses Claude Code — no parallel platform support needed.
- **Honest about influences.** Borrows the single-file skill format from [Superpowers](https://github.com/obra/superpowers) and the memory model from [ECC](https://github.com/affaan-m/ECC).
- **Hard non-goals.** No background observers. No on-by-default telemetry. No proprietary runtime.

## Scaffolding

To contribute a skill, command, or new subagent role:

```bash
# Skill
cp templates/skill.md skills/<your-name>/SKILL.md
$EDITOR skills/<your-name>/SKILL.md
./tests/validate-skills.sh    # must pass

# Slash command
$EDITOR commands/<your-name>.md
./tests/smoke.sh              # must pass

# New team role (subagent)
cp agents/orch-implementer.md agents/orch-<your-role>.md
$EDITOR agents/orch-<your-role>.md
./tests/validate-skills.sh
```

## Test discipline

Run the whole suite locally before pushing — it is what CI runs, and it is discovered from
the filesystem, so a new test file is picked up with no wiring:

```bash
./tests/run-all.sh           # every suite, ~3 minutes
```

The three fastest individually, while iterating:

```bash
./tests/validate-skills.sh   # structural: frontmatter, names, length
./tests/test-portability.sh  # bash 3.2 / BSD / macOS safe
./tests/smoke.sh             # behavior: hooks, lock, install, classifier (~90s)
```

A new assertion is not finished until you have seen it fail. Break the thing it guards,
watch it go red, then fix it. Several checks in this repo could never fail — a workflow
validator whose syntax layer returned 0 on invalid input, an installer check that shared
the blind spot of the code it checked — and every one of them was found by injecting a
defect, not by reading.

End-to-end testing inside a live Claude Code session: see [`docs/manual-testing.md`](./docs/manual-testing.md).

## Issue and PR format

Open issues with this shape:

```
Found:
- <symptom or gap>
Recommendation:
- <what you'd add/change>
Next:
- <smallest first step>
```

PRs should reference the issue, include a one-line `Verify:` step in the description (the command and its expected output), and keep diffs scoped to a single concern. Add one row to the relevant table in the README or `ARCHITECTURE.md` if your change is user-facing.

## Non-goals

These are durable. We will never:

- Ship a proprietary runtime.
- Enable telemetry by default.
- Accept more than ~40 first-party skills (cap stated in the philosophy bullets above).
- Add background observers. Memory should be something the user opts into via `/llm-orchestrator:remember`, not something that happens to them.

If your proposed contribution conflicts with a non-goal, open an issue first — these are durable but discussable.

## Tone

The skills, agents, and protocol all operate in the same register: confident, technical, specific. Concrete actions over abstract claims. Real numbers over adjectives. When in doubt, mirror the existing skill bodies — they're the canonical examples. Marketing flourishes ("blazing fast", "supercharge", "next-generation") will get edited out, so save us both the round trip and skip them.
