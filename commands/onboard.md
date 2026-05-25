---
description: One-time codebase onboarding — study architecture once, seed CLAUDE.md, never re-ask. Idempotent: skips if already onboarded.
---

You are running `/onboard`.

User input: $ARGUMENTS (ignored — onboarding is parameter-free)

**Onboarding is ONE-TIME.** This command has a single user-question surface (step 4 below). All per-task work after onboarding reads the recorded decisions silently, with no further questions.

## Steps

### 1. Idempotency check (ask-once guarantee)

```bash
DETECT_LIB=""
for p in \
    "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/orch-detect.sh" \
    "$HOME/.claude/llm-orchestrator/scripts/lib/orch-detect.sh" \
    "$(pwd)/.claude/scripts/lib/orch-detect.sh"; do
  [[ -f "$p" ]] && { DETECT_LIB="$p"; break; }
done
if [[ -z "$DETECT_LIB" ]]; then
  DETECT_LIB=$(find "$HOME/.claude/plugins" -name 'orch-detect.sh' -path '*llm-orchestrator*' 2>/dev/null | head -1)
fi
if [[ -z "$DETECT_LIB" || ! -f "$DETECT_LIB" ]]; then
  echo "orch-detect.sh not found. Reinstall the plugin." >&2
  exit 1
fi
source "$DETECT_LIB"
if orch_arch_cached "$PWD"; then
  echo "Already onboarded — re-run only after a major architecture change."
  exit 0
fi
```

If `orch_arch_cached "$PWD"` returns exit 0 (fingerprint matches, cache hit), print:

```
Already onboarded — re-run only after a major architecture change.
```

Then STOP. Do not study, draft, or ask anything.

### 2. Study (read-only)

Dispatch `orch-explorer` to map the codebase. The explorer must not edit anything.

Ask it to identify:

- **Stack** — language(s), runtime, framework(s)
- **Data layer / persistence** — databases, ORMs, file stores, caches
- **Offline / sync strategy** — if a client app: offline-first, optimistic updates, etc.
- **Module boundaries** — top-level packages, services, or domain areas and what owns what
- **Error-handling pattern** — how errors propagate (result types, exceptions, middleware, etc.)
- **Key dependencies** — the libraries the app is fundamentally built around (not utilities)

Also call the convention detector:

```bash
source "$DETECT_LIB"
orch_detect_conventions "$PWD"
```

Collect its output as the detected conventions block.

### 3. Draft

Produce a SHORT architecture summary containing:

1. **Architecture summary** — 3–6 bullet points covering the stack, data layer, module boundaries, error-handling, and offline strategy (if applicable).
2. **Detected conventions** — the `orch_detect_conventions` output formatted as a bullet list.
3. **Architectural decisions** — the load-bearing choices a future feature must not break (format: "we use X because Y / instead of Z"). Keep to 3–8 decisions.

### 4. Single approval gate (the ONLY place the user is asked)

Show the full draft to the user exactly once. Ask:

> "Write this to `./CLAUDE.md` under `## Decisions` and `## Conventions`? (yes / no)"

**On approval (yes):**

Locate `orch-lock.sh` and call `append_under_section` for each section:

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

# Append each decision bullet under ## Decisions
append_under_section "./CLAUDE.md" "Decisions" "- <decision> ($(date +%Y-%m-%d))"

# Append each convention bullet under ## Conventions
append_under_section "./CLAUDE.md" "Conventions" "- <convention> ($(date +%Y-%m-%d))"
```

This enhances the existing `CLAUDE.md` content — it never overwrites it.

**On decline (no):** Discard the draft. Write nothing. Report:

```
Changed:
- nothing written (user declined)
```

### 5. Record

After writing to `CLAUDE.md`, call `orch_arch_record` so the codebase is marked onboarded:

```bash
source "$DETECT_LIB"
orch_arch_record "$PWD" "<the decisions text>"
```

This is what lets per-task brainstorming read the decisions silently, with no further questions asked of the user.

### 6. Report

```
Changed:
- ./CLAUDE.md — appended under ## Decisions and ## Conventions
Verify:
- grep -A 20 "## Decisions" ./CLAUDE.md
Next:
- /plan or /dispatch to start feature work — decisions are now read silently per task.
```

## Constraints

- Read-only during study and draft. No file writes until the user approves in step 4.
- Never overwrite existing `CLAUDE.md` content — only append via `append_under_section`.
- Never re-study if `orch_arch_cached` returns exit 0. The ask-once guarantee is absolute.
- The approval gate in step 4 is the sole user-question surface for this command.
- Per-task work after onboarding reads the recorded decisions silently — no questions.
