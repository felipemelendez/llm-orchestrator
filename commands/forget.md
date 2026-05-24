---
description: Remove matching lines from CLAUDE.md or plugin memory. Soft-deletes to a trash directory so accidents are recoverable. Searches both user-facing memory (CLAUDE.md) and plugin memory (research config) and removes from wherever the match lives.
argument-hint: "[pattern]"
---

You are running `/forget`.

User input: $ARGUMENTS

Invoke the `memory` skill.

Steps:

1. Take `$ARGUMENTS` as a pattern. Empty → ask one short question.

2. **Regex safety:** treat the pattern as a literal substring, not a regex. Use `grep -F` (fixed string) for all matching, both showing and deleting.

3. **Catastrophic-delete guard:** refuse patterns of length < 3 characters, or patterns that match a `## ` section header. These would nuke too much.

4. **Build the candidate file list.** /forget doesn't ask the user where the fact lives — it searches everywhere a fact could be:
   ```bash
   CANDIDATES=()
   # Project-scope native memory
   [[ -f "./CLAUDE.md" ]] && CANDIDATES+=("./CLAUDE.md")
   [[ -f "./.claude/CLAUDE.md" ]] && CANDIDATES+=("./.claude/CLAUDE.md")
   # User-scope native memory
   [[ -f "$HOME/.claude/CLAUDE.md" ]] && CANDIDATES+=("$HOME/.claude/CLAUDE.md")
   # Plugin memory file (for research config / declined_mcp)
   ORCH_HOME="${ORCH_HOME:-$HOME/.llm-orchestrator}"
   if git rev-parse --show-toplevel >/dev/null 2>&1; then
     remote=$(git config --get remote.origin.url 2>/dev/null || true)
     if [[ -n "$remote" ]]; then PROJECT=$(printf '%s' "$remote" | shasum 2>/dev/null | cut -c1-12 || printf '%s' "$remote" | sha1sum | cut -c1-12)
     else PROJECT=$(printf '%s' "$(git rev-parse --show-toplevel)" | shasum 2>/dev/null | cut -c1-12 || printf '%s' "$(git rev-parse --show-toplevel)" | sha1sum | cut -c1-12); fi
   else
     PROJECT=$(printf '%s' "$PWD" | shasum 2>/dev/null | cut -c1-12 || printf '%s' "$PWD" | sha1sum | cut -c1-12)
   fi
   [[ -f "$ORCH_HOME/memory/$PROJECT.md" ]] && CANDIDATES+=("$ORCH_HOME/memory/$PROJECT.md")
   ```

5. Ensure trash dir:
   ```bash
   mkdir -p "$ORCH_HOME/memory/.trash"
   ```

6. Grep each candidate with `grep -inF -- "$PATTERN"` and collect matches (file + line + content).

7. If zero matches across all candidates → `Found: no matches.` and stop.

8. Hard cap: if total matches > 20 lines, refuse and tell the user to narrow the pattern.

9. Show the matches in a `Found:` block, grouped by file. Ask the user to confirm with the literal word `forget`. Anything else → abort.

10. Soft-delete under portable lock, per file that had matches:
    ```bash
    LOCK_LIB=""
    for p in \
        "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/orch-lock.sh" \
        "$HOME/.claude/llm-orchestrator/scripts/lib/orch-lock.sh" \
        "$(pwd)/.claude/scripts/lib/orch-lock.sh"; do
      [[ -f "$p" ]] && { LOCK_LIB="$p"; break; }
    done
    if [[ -z "$LOCK_LIB" ]]; then
      LOCK_LIB=$(find "$HOME/.claude/plugins" -name 'orch-lock.sh' -path '*llm-orchestrator*' 2>/dev/null | head -1)
    fi
    if [[ -z "$LOCK_LIB" || ! -f "$LOCK_LIB" ]]; then
      echo "orch-lock.sh not found. Reinstall the plugin." >&2
      exit 1
    fi
    source "$LOCK_LIB"

    TS=$(date +%Y%m%d-%H%M%S)
    NOW=$(date -Iseconds 2>/dev/null || date)
    for FILE in <files-with-matches>; do
      # Use a slug for the trash filename so each source has a distinct backup.
      SLUG=$(printf '%s' "$FILE" | tr '/' '-' | sed 's/^-//')
      TRASH="$ORCH_HOME/memory/.trash/${SLUG}-${TS}.md"
      with_lock "$FILE" bash -c '
        printf "# Soft-deleted %s from %s\n" "$1" "$2" > "$3"
        grep -nF -- "$4" "$2" >> "$3"
        grep -vF -- "$4" "$2" > "$2.new" && mv "$2.new" "$2"
      ' _ "$NOW" "$FILE" "$TRASH" "$PATTERN"
    done
    ```

11. Report:

```
Changed:
- <file-1> — removed <N> lines (backup: <trash-1>)
- <file-2> — removed <M> lines (backup: <trash-2>)
Verify:
- grep -F '<pattern>' <file-1>   # expect no hits
- cat <trash-1>                   # to restore: append matching content back
```

Constraints:
- Pattern is treated as a literal string (`grep -F`), never as a regex.
- Refuse patterns < 3 chars or matching a section header.
- Hard cap at 20 line deletions per invocation across all candidate files.
- Always show matches grouped by file before deleting.
- Always require literal `forget` confirmation.
- Always soft-delete to trash first.
- The user doesn't have to know which file the fact lives in — `/forget` searches everywhere.
