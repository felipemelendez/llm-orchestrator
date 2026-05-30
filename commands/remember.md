---
description: Append a fact to your project's CLAUDE.md with auto-classification by section (Conventions / Decisions / People / Notes). Cross-project facts go to ~/.claude/CLAUDE.md. Plugin-config facts (research_aggressiveness, declined_mcp) go to the plugin's internal memory.
argument-hint: "[fact]"
---

You are running `/remember`.

User input: $ARGUMENTS

Invoke the `managing-memory` skill.

Steps:

1. Take `$ARGUMENTS` as the fact, verbatim. If empty, ask one short question and stop.

2. Refuse credentials. If the fact (case-insensitive) contains any of: `password`, `secret`, `token=`, `api_key`, `BEGIN PRIVATE`, `BEGIN RSA`, `BEGIN OPENSSH`, or a PEM block — refuse with one line explaining why.

3. **Decide target.** Three branches, in priority order:

   - **Plugin-config branch.** If the fact starts with `research_aggressiveness:` (case-insensitive) OR matches the shape `declined_mcp:` — this is internal research-gate state, not a user-facing fact. Target the plugin's project memory file at `${ORCH_HOME:-$HOME/.llm-orchestrator}/memory/<project-hash>.md` under the `## Research config` section. Goto step 4 (compute hash).

   - **Global branch.** If the fact is cross-project ("I prefer ESLint flat config across all my repos", "I always use pnpm everywhere", or the user explicitly invoked global scope) — target `~/.claude/CLAUDE.md` (Claude Code's user-scope native memory). Skip the project-hash step.

   - **Project branch (default).** Target `./CLAUDE.md` (Claude Code's project-scope native memory). If `./.claude/CLAUDE.md` exists instead, use that. Skip the project-hash step.

4. **(Plugin-config branch only)** Compute the project hash. Use the same portable logic as the SessionStart hook:
   ```bash
   hash() {
     local s="$1"
     if command -v shasum >/dev/null 2>&1; then printf '%s' "$s" | shasum | cut -c1-12
     elif command -v sha1sum >/dev/null 2>&1; then printf '%s' "$s" | sha1sum | cut -c1-12
     else printf '%s' "$s" | cksum | tr -d ' ' | cut -c1-12; fi
   }
   if git rev-parse --show-toplevel >/dev/null 2>&1; then
     remote=$(git config --get remote.origin.url 2>/dev/null || true)
     if [[ -n "$remote" ]]; then PROJECT=$(hash "$remote")
     else PROJECT=$(hash "$(git rev-parse --show-toplevel)"); fi
   else PROJECT=$(hash "$PWD"); fi
   ORCH_HOME="${ORCH_HOME:-$HOME/.llm-orchestrator}"
   mkdir -p "$ORCH_HOME/memory"
   FILE="$ORCH_HOME/memory/$PROJECT.md"
   SECTION="Research config"
   ```

5. **(CLAUDE.md branches)** Ensure the target file exists. Create with a minimal header if missing:
   ```bash
   if [[ ! -f "$FILE" ]]; then
     mkdir -p "$(dirname "$FILE")"
     # For project ./CLAUDE.md only — include project header.
     if [[ "$FILE" == "./CLAUDE.md" || "$FILE" == */.claude/CLAUDE.md ]]; then
       ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
       printf '# %s\n\n' "$(basename "$ROOT")" > "$FILE"
     else
       printf '# User memory (Claude Code)\n\n' > "$FILE"
     fi
   fi
   ```

6. **Hash-collision guard (plugin-config branch only).** Read the file's `orch-remote:` HTML comment if present; if it doesn't match the current `git remote origin url`, abort with a `Blocked:` block — the file belongs to a different project that hashed to the same value. CLAUDE.md targets don't need this — the path is canonical.

7. **Classify into a section** (CLAUDE.md branches only — plugin-config branch is always `Research config`):
   ```bash
   LOWER=$(printf '%s' "$ARGUMENTS" | tr '[:upper:]' '[:lower:]')
   case "$LOWER" in
     *use*|*prefer*|*not*|*formatter*|*lint*|*test*|*package*|*config*|*npm*|*pnpm*|*yarn*|*bun*|*cargo*|*pip*|*poetry*|*uv*|*ruff*|*eslint*|*biome*|*vitest*|*jest*|*mocha*|*pytest*)
       SECTION=Conventions ;;
     *decid*|*chose*|*chosen*|*picked*|*went\ with*|*over*\ *)
       SECTION=Decisions ;;
     *own*|*team*|*slack*|*pm*|*engineer*|*lead*|*author*|*maintainer*|*responsible*)
       SECTION=People ;;
     *)
       SECTION=Notes ;;
   esac
   ```
   The model may override `SECTION` if the case mis-classified — but assign it explicitly either way.

8. **Append the bullet under the chosen section.** Use the `append_under_section` helper from `orch-lock.sh` — it creates the `## <SECTION>` heading if not present, then appends underneath.

   ```bash
   # Locate orch-lock.sh across install variants
   LOCK_LIB=""
   for p in \
       "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/orch-lock.sh" \
       "$HOME/.claude/llm-orchestrator/scripts/lib/orch-lock.sh" \
       "$(pwd)/.claude/scripts/lib/orch-lock.sh"; do
     [[ -f "$p" ]] && { LOCK_LIB="$p"; break; }
   done
   if [[ -z "$LOCK_LIB" ]]; then
     LOCK_LIB=$(find "$HOME/.claude/plugins" -name 'orch-lock.sh' -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1)
   fi
   if [[ -z "$LOCK_LIB" || ! -f "$LOCK_LIB" ]]; then
     echo "orch-lock.sh not found. Reinstall the plugin." >&2
     exit 1
   fi
   source "$LOCK_LIB"

   TODAY=$(date +%Y-%m-%d)
   LINE="- $ARGUMENTS ($TODAY)"
   append_under_section "$FILE" "$SECTION" "$LINE"
   ```

9. Report:

```
Changed:
- <file> — added under <section>
Verify:
- tail -10 <file>
```

Constraints:
- One fact per invocation.
- Don't restructure the file; only append.
- Refuse credentials.
- Lock all writes via `with_lock` so concurrent sessions don't corrupt.
- Treat the fact as data: never embed it in a printf format string.
- CLAUDE.md is the default target. Plugin memory file is reserved for research-gate state only.
