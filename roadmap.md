# Roadmap

## v0.1 — Foundation (this release)

- Concise Agent Protocol documented
- 16 skills (meta, brainstorming, writing-plans, executing-plans, TDD, systematic-debugging, worktrees, dispatch sequential, dispatch parallel, requesting/receiving review, verification-before-completion, finishing-a-branch, writing-skills, memory)
- 10 commands (`/init`, `/plan`, `/worktree`, `/dispatch`, `/review`, `/debug`, `/verify`, `/finish`, `/remember`, `/forget`)
- Hook profiles: minimal / standard / strict (`ORCH_HOOK_PROFILE`)
- Memory written to Claude Code's native CLAUDE.md by `/remember` (auto-classified); plugin memory at `~/.llm-orchestrator/memory/<hash>.md` reserved for research-gate state
- Skill linter (`tests/validate-skills.sh`)
- One worked example end-to-end
- Response-shape grader (`scripts/hooks/orch-protocol-grader.sh`, Stop hook; `ORCH_STRICT_PROTOCOL=1` to block; standalone CLI: `scripts/protocol-lint.sh`)
- Visual brainstorming: structured spec exploration with diagram output
- Adversarial spec/plan review: dedicated adversarial pass before implementation begins

## v0.2 — Hardening

- Worktree provenance enforced in `/finish` cleanup
- Cost tracker (JSONL only): `~/.llm-orchestrator/metrics/costs.jsonl` + `/cost` summary
- Context-budget audit + `/orch-doctor` to flag bloated skills/MCPs

## v0.3 — Cross-harness

- Codex mirror under `.codex/`
- Gemini mirror under `.gemini/`
- Copilot mirror under `.github/copilot/`
- `orch export --harness <name>` to generate mirrors from the source of truth
- Linter checks mirrors for drift

## v0.4 — Memory v2

- `/learn` extracts an instinct from the current session
- Atomic instinct YAML schema (id, trigger, action, confidence, scope)
- SessionStart injects top-N high-confidence instincts
- Still no background observer. Still opt-in. Still plain files.

## v0.5 — Ecosystem

- `orch skill new <name>` scaffolds from `templates/skill.md`
- `orch command new <name>` scaffolds a command
- A handful of optional contrib skills for common stacks (FastAPI, Next.js, Rails)

## Non-goals (durable)

- No proprietary runtime.
- No on-by-default telemetry.
- No skill catalog larger than ~40 first-party skills. Past that, discoverability dies.
- No surveillance hooks. No PostToolUse output capture. Memory is what the user opts into via `/remember`.

## Proposing changes

Open an issue with this format:

```
Found:
- <symptom or gap>

Recommendation:
- <what you'd add/change>

Next:
- <smallest first step>
```

// tested live on 2026-05-23
