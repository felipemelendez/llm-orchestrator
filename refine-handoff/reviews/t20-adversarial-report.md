Found seven issues. No files were edited. Transaction tests were blocked because the sandbox denied `/tmp` creation; executed probes below were read-only.

1. **CATASTROPHIC — agent creates a pseudo-terminal → confirmation can be forged — EXECUTED**: `tests/lib/terminal.py type` supplied `ruling 4` to the command’s terminal-read/check sequence; output: `confirmation accepted from program-created terminal`.
   **SCENE:** An agent supplies both the terminal and the answer. `/dev/tty` proves terminal availability, not owner participation. The commit hook checks the ruling’s contents, not who approved it. This gap is documented, but still defeats the stated boundary. **REASONED:** `cadence-ruling.sh:32,57`; `orch-cadence-check.sh:has_terminal`.

2. **CATASTROPHIC — patch changes during the confirmation prompt → unseen rules are applied — REASONED**: `skills/cadence/scripts/cadence-ruling.sh:main`, lines 40–66.
   **SCENE:** After validation, the agent replaces its patch file while the owner reads the prompt. Applying the patch reopens that mutable pathname without rechecking its contents or allowed paths. The replacement can also modify ordinary files; a valid numbered ruling still satisfies the commit hook.

3. **SERIOUS — rename starts outside the protected set → command deletes an unprotected file — EXECUTED**: A patch deleting `.githooks/commit-msg`, renaming `README.md` into that path, and adding Ruling 4 produced only protected destinations in `git apply --numstat`. `git apply --check --index` returned **0**.
   **SCENE:** The allowlist checks rename destinations but misses sources. Applying this accepted patch removes `README.md`. Evidence: `cadence-ruling.sh:40–44`. Mutation itself was not executed.

4. **SERIOUS — interruption or failed reversal → partial changes remain — REASONED**: `cadence-ruling.sh:undo` and lines 66–71.
   **SCENE:** Terminating after patch application leaves protected changes staged without the ruling commit; there is no signal/exit cleanup. Separately, if a rejecting commit hook modifies a patched file, reverse application can fail. `undo` ignores that failure, restores the old lock, and nevertheless says **“Nothing changed.”**

5. **SERIOUS — relative `--root` → another repository’s lock can be overwritten — REASONED**: `cadence-ruling.sh:35,69`; `orch-cadence-check.sh:resolve_root`.
   **SCENE:** From `/tmp`, `--root A` enters `/tmp/A`, then passes `A` unchanged to the checker. The checker now targets `/tmp/A/A`. If that directory contains another cadence repository, its lock is rewritten; rollback only restores the outer repository. Without that nested repository, an otherwise valid ruling fails.

6. **SERIOUS — dirty protected file plus inactive commit hook → successful commit contains an incorrect lock — REASONED**: `cadence-ruling.sh:46–71`; `orch-cadence-check.sh:mode_lock`.
   **SCENE:** Leave `.claude/settings.json` modified but unstaged and apply a laws-only patch. Preflight permits it. Re-locking hashes the dirty settings, but the commit includes their original indexed contents. Without the hook, the command reports success despite the mismatch. It neither requires the hook nor independently validates the staged lock.

7. **SERIOUS — protected path absent from the previous manifest → legitimate amendment is refused — EXECUTED**: This checkout’s allowlist excludes `CLAUDE.md`; adding its protected marked section passes `git apply --check --index` with **0**, but fails the command’s membership requirement.
   **SCENE:** The manifest records existing protected content, not every permissible protected path. Consequently, the new command cannot introduce that section through its advertised amendment path. **REASONED:** `cadence-ruling.sh:38–44`; checker `fixed_entries`.

What held up:

- Plain execution without a terminal refused with exit 1.
- Stale context, `..` traversal, and writes through a symlink were rejected by executed Git checks.
- Binary patch statistics exposed the destination for allowlist checking.
- Existing staged changes and dirty patch targets have explicit refusal checks; default invocation resolves the repository root from a subdirectory.
- Shell syntax and diff whitespace checks passed.

The owner loses the supported session-wide, noninteractive authorization path. Amendments introducing previously unrecorded protected paths also require a manual workaround outside this command. Manual owner edits remain possible.

**Verification: BLOCKED — full transaction and rollback tests require temporary writes unavailable in this sandbox.**