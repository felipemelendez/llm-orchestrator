---
description: List the orchestrator's skills and commands with their trigger conditions, so you can see what is available and when each fires.
---

You are running `/llm-orchestrator:skills`.

User input: $ARGUMENTS (optional — a keyword to filter by, matched against skill/command names and descriptions)

Purpose: give the user a one-screen catalog of what this plugin can do and when each piece fires. This is a discovery aid.

Source of truth: the skill and command catalog already injected into your context at session start (the `using-orchestrator` meta-skill and the available-skills list). Do NOT shell out to find files — the plugin's install path is not reliably available from a command's working directory, and globbing for it fails. Render the list you already have.

Steps:

1. From the skills available in this session and the `/llm-orchestrator:*` commands, build the catalog. Do not invent entries; list only what is actually present.

2. If `$ARGUMENTS` is non-empty, keep only entries whose name or description contains that keyword (case-insensitive).

3. Present the result as a `Found:` block. Group the skills:
   - **Process** — brainstorming, research-classifier, systematic-debugging
   - **Build** — writing-plans, executing-plans, test-driven-development, dispatching-subagents, dispatching-parallel-agents, using-workflows
   - **Review & finish** — requesting-code-review, receiving-code-review, verification-before-completion, finishing-a-branch
   - **Context & memory** — handing-off-to-fresh-context, managing-memory, using-orchestrator
   - **Git** — using-git-worktrees
   - **Meta** — writing-skills

   Put anything that does not fit into an **Other** group rather than dropping it. List the `/llm-orchestrator:*` commands under their own **Commands** heading.

4. Each row is one line: the name, then a short paraphrase of its "Use when" trigger — trigger first, mechanics second.

5. End with one `Recommendation:` line pointing at the usual entry points: `/llm-orchestrator:onboard` for a new project, `brainstorming` for a new feature, `/llm-orchestrator:plan` once a spec is approved.

Constraints:
- One line per skill/command. No padding.
- Do not run Bash to enumerate files. Render from the in-context catalog.
- Do not invent skills or commands that are not actually available this session.
