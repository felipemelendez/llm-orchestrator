# CLAUDE.md

This project uses LLM Orchestrator. The agent follows the Concise Agent Protocol — replies land in one of six fixed shapes (`Changed`, `Found`, `Blocked`, `Issues`, `Plan`, `Status`). No preamble. No trailing summaries.

Full reference: the protocol doc inside the LLM Orchestrator install.

## Project notes

(Add your project-specific conventions here. They will be read by the agent at the start of every session.)

- Language / framework:
- Test command:
- Lint command:
- Branch naming:
- Anything else the agent must respect:

## Commands available

When LLM Orchestrator is installed, these slash commands work in this project:

- `/plan`, `/worktree`, `/dispatch`, `/review`, `/verify`, `/finish`
- `/debug` for root-cause-first investigation
- `/remember`, `/forget` for project memory (writes to this CLAUDE.md, classified by section)

## Notes for the agent

- Plan before non-trivial implementation.
- Verify before claiming "done" — run the command, paste the line.
- Use git worktrees for parallel-branch work.
- Ask one targeted question rather than guessing.
