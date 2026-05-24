# Contributing

Contributions welcome — small skill additions, new subagent roles, hook improvements, and docs fixes all land cleanly. First-time contributors are welcome; the scaffolding below shows what a clean change looks like.

This is intentionally a small, opinionated kit:

- **Pure markdown + shell.** No runtime to learn. No build step. Add a skill by copying `templates/skill.md`.
- **Small catalog (16 skills).** Your contribution actually gets noticed and used. Past ~40 skills the catalog gets unscannable — we cap there on purpose.
- **Real test suite.** Three scripts (`smoke.sh`, `validate-skills.sh`, `test-portability.sh`) run in seconds and gate every commit. They catch regressions in JSON schemas, hook output formats, concurrency, portability (bash 3.2 / BSD / macOS), and shape-checking.
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

Three scripts gate every commit. Run them locally before pushing:

```bash
./tests/validate-skills.sh   # structural: frontmatter, names, length
./tests/test-portability.sh  # bash 3.2 / BSD / macOS safe
./tests/smoke.sh             # behavior: hooks, lock, install, classifier (~5s)
```

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

PRs should reference the issue, include a one-line `Verify:` step in the description (the command and its expected output), and keep diffs scoped to a single concern. Add one row to the relevant table in the README or `architecture.md` if your change is user-facing.

## Non-goals

These are durable. We will never:

- Ship a proprietary runtime.
- Enable telemetry by default.
- Accept more than ~40 first-party skills. Past that, the catalog becomes unscannable.
- Add background observers. Memory should be something the user opts into via `/remember`, not something that happens to them.

If your proposed contribution conflicts with a non-goal, open an issue first — these are durable but discussable.

## Tone

The skills, agents, and protocol all operate in the same register: confident, technical, specific. Concrete actions over abstract claims. Real numbers over adjectives. When in doubt, mirror the existing skill bodies — they're the canonical examples. Marketing flourishes ("blazing fast", "supercharge", "next-generation") will get edited out, so save us both the round trip and skip them.
