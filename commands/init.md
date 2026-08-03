---
description: Initialize LLM Orchestrator conventions in the current project. Adds CLAUDE.md, AGENTS.md, .gitignore entries, and the docs/llm-orchestrator/ scaffold without overwriting existing files.
---

You are running `/llm-orchestrator:init` for LLM Orchestrator.

User input: $ARGUMENTS (optional — accepts `--force` to overwrite existing scaffolding)

Steps:

1. Detect repo root:
   ```bash
   ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
   ```

2. Check for existing files:
   - `CLAUDE.md`, `AGENTS.md`
   - `docs/llm-orchestrator/`

3. For missing files, write minimal versions from `templates/scaffold-CLAUDE.md` and `templates/scaffold-AGENTS.md`.

4. Create directories:
   ```bash
   mkdir -p docs/llm-orchestrator/{specs,plans,reviews,research,handoffs}
   ```

5. Ensure `.gitignore` contains (only if not already present):
   ```
   .orch-cache/
   .orch-worktree
   .worktrees/
   ```

6. If `CLAUDE.md` already exists, append a single pointer section to the protocol — do not overwrite. Skip the append if a `## Concise Agent Protocol` heading already exists.

7. Report:

```
Changed:
- created CLAUDE.md (or appended pointer)
- created AGENTS.md (or kept existing)
- created docs/llm-orchestrator/{specs,plans,reviews,research,handoffs}/
- appended .gitignore entries
Verify:
- ls docs/llm-orchestrator/
- head -20 CLAUDE.md
Next:
- /llm-orchestrator:remember any project-specific conventions
- Use the `brainstorming` skill or `/llm-orchestrator:plan` when you have a spec
```

Constraints:
- Do not edit `package.json`, lockfiles, CI configs, or anything outside the scaffold list.
- If the project is a monorepo (multiple package.json), ask which package to scaffold for.
