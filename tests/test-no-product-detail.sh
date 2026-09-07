#!/usr/bin/env bash
# No product detail from a private codebase may reach the public tree.
#
# The cadence was built inside one private application, and the shapes that
# travel out of a place like that are always the same four: an absolute home
# path, a private ticket id, a numbered ruling, a numbered session. This suite
# scans the SHIPPED surface for them — skills, commands, templates, scripts,
# hooks, workflows, agents and the top-level documents, every text file of them
# whatever its extension — and excludes docs/llm-orchestrator/ (working notes,
# gitignored) and tests/ (this file has to be able to name the patterns it
# looks for).
#
# Each pattern is proven to FIRE on a seeded fixture before the tree is scanned:
# a leakage scan that cannot go red is decoration.
#
# A project-specific denylist (words, product names) is read from the file named
# by ORCH_PRIVATE_DENYLIST, one extended regular expression per line. It is never
# committed. When the variable is unset the suite says so out loud rather than
# reporting a clean scan it did not run.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# The public patterns. `/Users/[A-Za-z]` and not a bare `/Users/`: the install
# docs legitimately carry a `/Users/.../` placeholder, and a pattern that fires
# on the placeholder gets switched off within a week.
PUBLIC_PATTERNS=(
  '/Users/[A-Za-z]'
  '\bT-[A-Z0-9-]+\b'
  '[Rr]uling [0-9]+'
  '[Ss]ession [0-9]+'
)

# No extension list. A hook copied into a project (`commit-msg`, `pre-commit`)
# has no suffix, and an allow-list of extensions would leave exactly those files
# — the ones most likely to carry a machine's own paths — unscanned. Every
# regular text file under the roots is read; -I keeps binaries out and .git is
# excluded by name.
GREP_OPTS=(-rnEI --exclude-dir=.git)

roots_under() { # roots_under <base> — only the ones that exist
  local b="$1" p
  for p in skills commands templates scripts hooks workflows agents \
           README.md ARCHITECTURE.md CHANGELOG.md AGENTS.md CONTRIBUTING.md; do
    [ -e "$b/$p" ] && printf '%s\n' "$b/$p"
  done
  # docs/*.md only: docs/llm-orchestrator/ is working notes and never shipped
  for p in "$b"/docs/*.md; do [ -f "$p" ] && printf '%s\n' "$p"; done
}

scan_at() { # scan_at <base> <pattern...> — prints `file:line: text` per hit
  local b="$1"; shift
  local roots=() r pat
  while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done < <(roots_under "$b")
  [ ${#roots[@]} -eq 0 ] && return 0
  for pat in "$@"; do
    grep "${GREP_OPTS[@]}" -e "$pat" "${roots[@]}" 2>/dev/null \
      | grep -v "/docs/llm-orchestrator/" \
      | grep -v "/tests/" \
      | sed 's|^\([^:]*:[0-9]*:\)|\1 |'
  done
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- each pattern must fire on a seeded fixture ------------------------------
printf '%s== every public pattern goes red on a seeded string ==%s\n' "$DIM" "$RESET"
FX="$TMP/fixture"
mkdir -p "$FX/skills/demo" "$FX/scripts" "$FX/docs/llm-orchestrator" "$FX/tests" "$FX/docs"
printf 'a home path: /Users/someone/Projects/thing\n'      > "$FX/skills/demo/SKILL.md"
printf 'the ticket T-SOME-TICKET landed\n'                  > "$FX/scripts/one.sh"
printf 'per Ruling 41 the seat re-enters\n'                 > "$FX/docs/guide.md"
printf 'in session 7 the gate caught it\n'                  > "$FX/README.md"
printf 'excluded: /Users/someone/private and T-HIDDEN\n'    > "$FX/docs/llm-orchestrator/notes.md"
printf 'excluded: /Users/someone/private and T-HIDDEN\n'    > "$FX/tests/test-x.sh"
printf 'the placeholder /Users/.../project stays legal\n'   > "$FX/CONTRIBUTING.md"

i=0
for pat in "${PUBLIC_PATTERNS[@]}"; do
  n=$(scan_at "$FX" "$pat" | grep -c . | tr -d ' ')
  if [ "${n:-0}" -ge 1 ]; then ok "pattern fires: $pat"; else fail "pattern is dead: $pat" "no hit on the seeded fixture"; fi
  i=$((i+1))
done
HITS=$(scan_at "$FX" "${PUBLIC_PATTERNS[@]}")
if ! printf '%s\n' "$HITS" | grep -q 'llm-orchestrator/notes.md'; then ok "docs/llm-orchestrator/ is excluded"; else fail "exclusion" "notes.md was scanned"; fi
if ! printf '%s\n' "$HITS" | grep -q 'tests/test-x.sh'; then ok "tests/ is excluded"; else fail "exclusion" "tests/ was scanned"; fi
if ! printf '%s\n' "$HITS" | grep -q 'CONTRIBUTING.md'; then ok "the /Users/.../ placeholder does not false-fire"; else fail "placeholder" "$(printf '%s\n' "$HITS" | grep CONTRIBUTING)"; fi
if printf '%s\n' "$HITS" | grep -qE '^[^:]+:[0-9]+: '; then ok "hits print as file:line: text"; else fail "hit format" "$(printf '%s\n' "$HITS" | head -2)"; fi

# --- files with no extension are shipped too ---------------------------------
# A git hook copied into a project has no suffix, so an extension list is a hole
# in the scan rather than a filter.
printf '\n%s== a file with no extension is scanned ==%s\n' "$DIM" "$RESET"
mkdir -p "$FX/skills/demo/references"
printf 'a path: /Users/somebody/private/thing\n' > "$FX/skills/demo/references/commit-msg"
EXTLESS=$(scan_at "$FX" '/Users/[A-Za-z]' | grep -c 'references/commit-msg' | tr -d ' ')
[ "${EXTLESS:-0}" -ge 1 ] && ok "an extensionless file under a scanned root goes red" || fail "extensionless blind spot" "no hit in skills/demo/references/commit-msg"
printf 'binary /Users/somebody/private\000\001\002\n' > "$FX/skills/demo/references/blob.bin"
BINHIT=$(scan_at "$FX" '/Users/[A-Za-z]' | grep -c 'blob.bin' | tr -d ' ')
[ "${BINHIT:-0}" -eq 0 ] && ok "a binary file is still skipped (-I)" || fail "binary scanned" "blob.bin was reported"
rm -f "$FX/skills/demo/references/blob.bin"

# --- the private denylist ----------------------------------------------------
printf '\n%s== the private denylist ==%s\n' "$DIM" "$RESET"
DENY="$TMP/deny.txt"
printf '%s\n' 'WidgetFactoryPro' '[Ss]print [0-9]+' > "$DENY"
printf 'the WidgetFactoryPro flow\n' > "$FX/scripts/two.sh"
DN=$(while IFS= read -r p; do [ -n "$p" ] && scan_at "$FX" "$p"; done < "$DENY" | grep -c . | tr -d ' ')
[ "${DN:-0}" -ge 1 ] && ok "a denylist entry is found when one is supplied" || fail "denylist" "no hit for a seeded denylist word"
rm -f "$FX/scripts/two.sh"

# --- the real tree -----------------------------------------------------------
printf '\n%s== the shipped tree ==%s\n' "$DIM" "$RESET"
TREE_HITS=$(scan_at "$ROOT" "${PUBLIC_PATTERNS[@]}")
if [ -z "$TREE_HITS" ]; then
  ok "no public product-detail pattern appears in the shipped tree"
else
  fail "product detail in the shipped tree" "$(printf '%s\n' "$TREE_HITS" | head -20)"
fi

if [ -n "${ORCH_PRIVATE_DENYLIST:-}" ] && [ -f "${ORCH_PRIVATE_DENYLIST}" ]; then
  DENY_HITS=$(while IFS= read -r p; do [ -n "$p" ] && scan_at "$ROOT" "$p"; done < "${ORCH_PRIVATE_DENYLIST}")
  if [ -z "$DENY_HITS" ]; then ok "no private denylist entry appears in the shipped tree"
  else fail "denylist entry in the shipped tree" "$(printf '%s\n' "$DENY_HITS" | head -20)"; fi
else
  printf '  %s-%s the private denylist was NOT applied: ORCH_PRIVATE_DENYLIST is unset or not a file\n' "$DIM" "$RESET"
  printf '  %s-%s   set it to a file of one extended regular expression per line to scan for project words\n' "$DIM" "$RESET"
fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-no-product-detail%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-no-product-detail — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
