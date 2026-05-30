#!/usr/bin/env bash
# Regression guard for plugin-lib path resolution in commands and skills.
#
# Re-exec under bash if invoked under another shell (e.g. zsh). This guard is
# itself about cross-shell safety, so it must not silently no-op under zsh —
# where unquoted parameters are not field-split and bash arrays/`<<<` differ.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
#
# Bug class (fixed): a command/skill that sources a plugin lib by a cwd-relative
# path (e.g. `source scripts/lib/orch-detect.sh`) breaks at runtime, because the
# model runs that bash with cwd set to the USER'S project — not the plugin dir —
# and $CLAUDE_PLUGIN_ROOT is frequently unset in command/skill bash. Marketplace
# installs also nest the libs under ~/.claude/plugins/cache/<mp>/<plugin>/<ver>/,
# so a naive `find ... | head -1` can source a STALE older version. And libs that
# self-locate via bare ${BASH_SOURCE[0]} break when sourced under zsh.
#
# Invariants enforced:
#   A. No bare relative source of scripts/ (any of: `source`/`.`, single or double
#      quoted, with `./` or `../` prefixes) in commands/ or skills/.
#   B. Every plugin-cache find used to locate a lib is version-aware
#      (`sort -V | tail -1`), never `head -1`.
#   C. Any file that sources a lib carries the `$HOME/.claude/plugins` find fallback.
#   D. Libs self-locate cross-shell via ${BASH_SOURCE[0]:-$0}.
#   E. The Check-A matcher itself catches every equivalent bad form and rejects
#      the resolved-variable and backtick-prose forms (guards the guard).
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIRS=("$ROOT/commands" "$ROOT/skills")

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Matcher for a bare relative source of scripts/: the `source` keyword OR a POSIX
# dot-source `.`, as a command (line start or after a non-name char), then an
# optional quote, optional ./ or ../ prefixes, then `scripts/`. The resolved form
# `source "$L"` and backtick prose `source `scripts/…`` do not match (no quote is
# a backtick; after a quote must come ./../ or `scripts`, not `$`).
A_RE='(^|[^[:alnum:]_./])(source|\.)[[:space:]]+['\''"]?(\.\.?/)*scripts/'

# grep over the directories directly (grep does the recursion) so the test never
# depends on shell word-splitting of a path list.
grep_dirs() { grep -rnE "$1" "${DIRS[@]}" --include='*.md' 2>/dev/null || true; }

printf '%s== E. the Check-A matcher is correct (guards the guard) ==%s\n' "$DIM" "$RESET"
mok=1
for s in \
  'source scripts/lib/x.sh' \
  'source "scripts/lib/x.sh"' \
  "source 'scripts/lib/x.sh'" \
  'source ./scripts/lib/x.sh' \
  'source ../scripts/lib/x.sh' \
  '. scripts/lib/x.sh' \
  '  . ./scripts/lib/x.sh'; do
  printf '%s\n' "$s" | grep -qE "$A_RE" || { fail "matcher MUST catch: $s" ""; mok=0; }
done
for s in \
  'source "$L"' \
  'L=$(orch_lib orch-detect.sh)' \
  'orch_lib() { local n="$1"; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n"; do :; done; }' \
  '   - Check (source `scripts/lib/orch-signals.sh` for `$ORCH_SIG`):'; do
  printf '%s\n' "$s" | grep -qE "$A_RE" && { fail "matcher MUST NOT match: $s" ""; mok=0; }
done
(( mok == 1 )) && ok "matcher catches source/dot-source × quotes × ./../ ; rejects resolved-var and backtick prose"

printf '\n%s== A. no bare relative source of scripts/ ==%s\n' "$DIM" "$RESET"
BARE=$(grep_dirs "$A_RE")
if [[ -z "$BARE" ]]; then
  ok "no command/skill sources a cwd-relative scripts/ path"
else
  fail "found bare relative source of scripts/ (breaks outside the plugin dir)" "$(printf '%s' "$BARE" | head -5)"
fi

printf '\n%s== B. plugin-cache find is version-aware (sort -V | tail -1, never head -1) ==%s\n' "$DIM" "$RESET"
BADHEAD=$(grep_dirs 'find "\$HOME/\.claude/plugins".*-path .\*llm-orchestrator\*.*head[[:space:]]+-(n[[:space:]]*)?1')
if [[ -z "$BADHEAD" ]]; then
  ok "no lib-locating find uses 'head -1' (would risk a stale version)"
else
  fail "lib-locating find uses 'head -1' — use 'sort -V | tail -1'" "$(printf '%s' "$BADHEAD" | head -5)"
fi

printf '\n%s== C. every lib source has the find fallback ==%s\n' "$DIM" "$RESET"
# Files that locate a lib via the resolver/find idiom must contain the
# $HOME/.claude/plugins find fallback so a marketplace/cache install resolves.
SOURCERS=$(grep -rlE 'orch_lib\(\)|_LIB=\$\(find' "${DIRS[@]}" --include='*.md' 2>/dev/null || true)
if [[ -z "$SOURCERS" ]]; then
  ok "no lib-sourcing files to check (vacuously true)"
else
  bad=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qE 'find "\$HOME/\.claude/plugins"' "$f" || { fail "$f: sources a lib but lacks the \$HOME/.claude/plugins find fallback" ""; bad=1; }
  done <<< "$SOURCERS"
  (( bad == 0 )) && ok "all lib-sourcing files include the plugin-cache find fallback"
fi

printf '\n%s== D. scripts self-locate cross-shell (BASH_SOURCE...:-$0) ==%s\n' "$DIM" "$RESET"
# Any dirname-based self-location off BASH_SOURCE (with or without [0]/braces)
# must carry a :- fallback, or it collapses to cwd under zsh. Scope is all of
# scripts/ (libs AND hooks). The sourced-vs-executed guard in orch-protocol.sh
# (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`, no dirname) is correctly NOT matched.
BADSELF=$(grep -rnE 'dirname "[^"]*\$\{?BASH_SOURCE' "$ROOT/scripts" 2>/dev/null | grep -v ':-' || true)
if [[ -z "$BADSELF" ]]; then
  ok "all script self-dir resolutions carry a \${BASH_SOURCE...:-\$0} fallback (zsh-safe)"
else
  fail "self-dir off BASH_SOURCE lacks a :- fallback — breaks under zsh" "$(printf '%s' "$BADSELF" | head -5)"
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
