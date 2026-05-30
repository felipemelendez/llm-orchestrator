#!/usr/bin/env bash
# Regression guard for plugin-lib path resolution in commands and skills.
#
# Bug class (fixed): a command/skill that sources a plugin lib by a cwd-relative
# path (e.g. `source scripts/lib/orch-detect.sh`) breaks at runtime, because the
# model runs that bash with cwd set to the USER'S project — not the plugin dir —
# and $CLAUDE_PLUGIN_ROOT is frequently unset in command/skill bash. Marketplace
# installs also nest the libs under ~/.claude/plugins/cache/<mp>/<plugin>/<ver>/,
# so a naive `find ... | head -1` can source a STALE older version.
#
# This test enforces the two invariants of the fix:
#   A. No bare relative `source scripts/...` anywhere in commands/ or skills/.
#   B. Every plugin-cache find used to locate a lib is version-aware
#      (`sort -V | tail -1`), never `head -1`.
#   C. Any file that sources an orch-*.sh lib carries the robust find fallback
#      (`find "$HOME/.claude/plugins" ... -path '*llm-orchestrator*'`).
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

FILES=$(find "$ROOT/commands" "$ROOT/skills" -name '*.md' 2>/dev/null | sort)

printf '%s== A. no bare relative `source scripts/...` ==%s\n' "$DIM" "$RESET"
# Match a `source` of a relative scripts/ path. The robust resolver sources a
# RESOLVED absolute path held in a variable (e.g. `source "$L"`), which this
# pattern does not match.
BARE=$(grep -rnE 'source[[:space:]]+"?\.?/?scripts/' $FILES 2>/dev/null || true)
if [[ -z "$BARE" ]]; then
  ok "no command/skill sources a cwd-relative scripts/ path"
else
  fail "found bare relative source of scripts/ (will break outside the plugin dir)" "$(printf '%s' "$BARE" | head -5)"
fi

printf '\n%s== B. plugin-cache find is version-aware (sort -V | tail -1, never head -1) ==%s\n' "$DIM" "$RESET"
BADHEAD=$(grep -rnE 'find "\$HOME/\.claude/plugins".*-path .\*llm-orchestrator\*.*head -1' $FILES 2>/dev/null || true)
if [[ -z "$BADHEAD" ]]; then
  ok "no lib-locating find uses 'head -1' (would risk a stale version)"
else
  fail "lib-locating find uses 'head -1' — use 'sort -V | tail -1'" "$(printf '%s' "$BADHEAD" | head -5)"
fi

CACHE_FINDS=$(grep -rlE 'find "\$HOME/\.claude/plugins".*-path .\*llm-orchestrator\*' $FILES 2>/dev/null || true)
if [[ -n "$CACHE_FINDS" ]]; then
  bad=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qE 'find "\$HOME/\.claude/plugins".*llm-orchestrator.*(head -1|tail -1)' "$f"; then
      if ! grep -qE 'sort -V[[:space:]]*\|[[:space:]]*tail -1' "$f"; then
        fail "$f: lib find is not version-sorted" "expected 'sort -V | tail -1'"; bad=1
      fi
    fi
  done <<< "$CACHE_FINDS"
  (( bad == 0 )) && ok "all lib-locating finds version-sort before selecting"
fi

printf '\n%s== C. every orch-*.sh source has the find fallback ==%s\n' "$DIM" "$RESET"
# Files that source an orch lib (via the resolved var pattern) must also contain
# the find fallback so a marketplace/cache install resolves.
SOURCERS=$(grep -rlE 'orch_lib [a-z]|_LIB=\$\(find|source "\$(LOCK_LIB|DETECT_LIB|L)"' $FILES 2>/dev/null || true)
if [[ -z "$SOURCERS" ]]; then
  ok "no lib-sourcing files to check (vacuously true)"
else
  bad=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! grep -qE 'find "\$HOME/\.claude/plugins"' "$f"; then
      fail "$f: sources a lib but lacks the \$HOME/.claude/plugins find fallback" ""; bad=1
    fi
  done <<< "$SOURCERS"
  (( bad == 0 )) && ok "all lib-sourcing files include the plugin-cache find fallback"
fi

printf '\n%s== D. libs self-locate cross-shell (BASH_SOURCE[0]:-$0) ==%s\n' "$DIM" "$RESET"
# A lib sourced into the model's shell may run under zsh, where BASH_SOURCE is
# unset. Any lib that resolves its own dir to source siblings must fall back to
# $0, or the sibling source resolves against the caller's cwd and fails.
BADSELF=$(grep -rnE 'dirname "\$\{BASH_SOURCE\[0\]\}"' "$ROOT/scripts/lib" 2>/dev/null || true)
if [[ -z "$BADSELF" ]]; then
  ok "all lib self-dir resolutions use \${BASH_SOURCE[0]:-\$0} (zsh-safe)"
else
  fail "lib self-dir uses bare \${BASH_SOURCE[0]} — breaks when sourced under zsh" "$(printf '%s' "$BADSELF" | head -5)"
fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-lib-resolution%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-lib-resolution — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
