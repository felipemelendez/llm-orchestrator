Three issues remain. No files were edited; no model calls were made.

Round 1 status:

1. **Not fixed:** session variables can be removed before supplying a program-created terminal.
2. **Fixed:** validation and application use a private patch copy.
3. **Fixed:** mismatched paths, renames and copies are rejected.
4. **Partly fixed:** interruption cleanup and error reporting exist, but rollback can delete unrelated work.
5. **Fixed:** explicit `--root` becomes absolute.
6. **Fixed:** protected-file cleanliness and post-commit audit checks were added.
7. **Partly fixed:** missing paths are allowed, but adding a section to an existing file still fails.

1. **CATASTROPHIC — program-created terminal → forged confirmation — EXECUTED.**
   **SCENE:** Remove the four session variables and use `tests/lib/terminal.py type` to supply `ruling 4`. The current guard/read sequence accepted it: `confirmation accepted from program-created terminal after removing session variables`. The environment check does not establish owner participation. Evidence: [cadence-ruling.sh:88](/Users/felipe/src/llm-orchestrator-wt/t20-ruling-command/skills/cadence/scripts/cadence-ruling.sh:88).

2. **CATASTROPHIC — failed application → untracked owner file deleted — EXECUTED WITH FAKE GIT; transaction REASONED.**
   **SCENE:** A patch adds `CLAUDE.md`, but an untracked copy already contains the owner’s instructions. Preflight ignores untracked files; scratch-index validation permits the addition. Real application refuses the existing file, but `STATE=applied` already triggers rollback. Rollback deletes paths absent from HEAD. The in-memory probe deleted the simulated owner file, then printed **“The change was undone; nothing changed.”** Evidence: [preflight:140](/Users/felipe/src/llm-orchestrator-wt/t20-ruling-command/skills/cadence/scripts/cadence-ruling.sh:140), [application:171](/Users/felipe/src/llm-orchestrator-wt/t20-ruling-command/skills/cadence/scripts/cadence-ruling.sh:171), [deletion:43](/Users/felipe/src/llm-orchestrator-wt/t20-ruling-command/skills/cadence/scripts/cadence-ruling.sh:43).

3. **SERIOUS — first protected section in an existing file → legitimate amendment refused — EXECUTED.**
   **SCENE:** A tracked `CLAUDE.md` contains only `@AGENTS.md`. Append its first protected section without changing that line. `outside_section` inserts a placeholder only into the resulting version, so comparison reports an outside-section edit. The extracted-function probe reproduced this rejection. Evidence: [cadence-ruling.sh:155](/Users/felipe/src/llm-orchestrator-wt/t20-ruling-command/skills/cadence/scripts/cadence-ruling.sh:155).

**Verification: BLOCKED — full transaction tests require writes. Read-only probes, shell syntax and diff whitespace checks ran successfully.**