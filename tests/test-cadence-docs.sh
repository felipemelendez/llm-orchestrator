#!/usr/bin/env bash
# Drift test: the cadence's names must be spelled the same everywhere they appear.
#
# The cadence is described in four places that no compiler relates — the skill
# (SKILL.md / CADENCE.md), the README, docs/install.md, and the check script's
# own --help — and a mode or a file renamed in one of them reads as correct
# until someone types it. This suite pins the spellings, both directions where
# it can: every mode the script's usage line advertises must appear in the
# skill's text, and the heading the init prints a reader toward must exist.
#
# Scope note, stated because a silent exclusion reads as coverage: the
# deleted-guard scan below covers the SHIPPED surface (scripts, hooks, skills,
# commands, templates, docs and the top-level markdown) and deliberately not
# tests/, where two suites name the deleted guard in order to assert it is gone.
#
# Usage: bash tests/test-cadence-docs.sh
# Exit codes: 0 = all checks passed, 1 = at least one failed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/cadence/SKILL.md"
FULL="$ROOT/skills/cadence/CADENCE.md"
README="$ROOT/README.md"
INSTALL="$ROOT/docs/install.md"
CHECK="$ROOT/skills/cadence/scripts/orch-cadence-check.sh"
INIT="$ROOT/skills/cadence/scripts/cadence-init.sh"
LOCK_HEADING="The lock's two layers"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }

for f in "$SKILL" "$FULL" "$README" "$INSTALL" "$CHECK" "$INIT"; do
  [ -f "$f" ] || { printf 'FAIL: missing %s\n' "$f"; exit 1; }
done

printf '\n== The check script'"'"'s modes ==\n'
USAGE="$(bash "$CHECK" --help 2>&1 | head -1)"
for m in --verdict --lock --landing --commit-msg --audit --version; do
  case "$USAGE" in
    *"$m"*) ok "$m is in the usage line" ;;
    *)      fail "$m in the usage line" "--help does not advertise it: $USAGE" ;;
  esac
  if has "$SKILL" "$m" || has "$FULL" "$m"; then
    ok "$m is named in the skill's text"
  else
    fail "$m in the skill's text" "neither SKILL.md nor CADENCE.md names it"
  fi
done
# The two modes a person types by hand belong in the user-facing guide.
for m in --lock --audit; do
  has "$INSTALL" "$m" && ok "$m is named in docs/install.md" \
    || fail "$m in docs/install.md" "the install guide never spells it"
done

printf '\n== The lock set, the state file ==\n'
for n in "docs/llm-orchestrator/LAWS.md" "cadence.json" "LOCK.sha256" \
         ".githooks/commit-msg" ".githooks/orch-cadence-check.sh"; do
  if has "$SKILL" "$n" || has "$FULL" "$n"; then ok "$n in the skill's text"
  else fail "$n in the skill's text" "neither SKILL.md nor CADENCE.md names it"; fi
  has "$INSTALL" "$n" && ok "$n in docs/install.md" \
    || fail "$n in docs/install.md" "the install guide never spells it"
done
if has "$SKILL" "CADENCE_STATE.md" || has "$FULL" "CADENCE_STATE.md"; then
  ok "CADENCE_STATE.md in the skill's text"
else
  fail "CADENCE_STATE.md in the skill's text" "the skips file is unnamed"
fi

printf '\n== Two layers, not three, and no deleted guard ==\n'
has "$INSTALL" "### $LOCK_HEADING" && ok "docs/install.md carries the heading \"$LOCK_HEADING\"" \
  || fail "the heading \"$LOCK_HEADING\"" "docs/install.md has no such section heading"
has "$README" "two layers" && ok "the README names the lock's two layers" \
  || fail "the README's two layers" "the cadence section does not say two layers"
SHIPPED="$ROOT/scripts $ROOT/hooks $ROOT/skills $ROOT/commands $ROOT/templates $ROOT/docs"
# shellcheck disable=SC2086
THREE=$(grep -rlF "lock's three layers" $SHIPPED "$ROOT/README.md" "$ROOT/ARCHITECTURE.md" \
        "$ROOT/CHANGELOG.md" "$ROOT/AGENTS.md" 2>/dev/null)
[ -z "$THREE" ] && ok "nothing shipped still says three layers" \
  || fail "three layers" "still written in: $THREE"
# shellcheck disable=SC2086
GONE=$(grep -rlF "guard-cadence-lock" $SHIPPED "$ROOT/README.md" "$ROOT/ARCHITECTURE.md" \
       "$ROOT/CHANGELOG.md" "$ROOT/AGENTS.md" 2>/dev/null)
[ -z "$GONE" ] && ok "no shipped file names the deleted shell guard" \
  || fail "the deleted shell guard" "still named in: $GONE"

printf '\n== The init points at headings that exist ==\n'
# The tip prints: ... (see docs/install.md, "The lock's two layers")
TIP=$(grep -F 'docs/install.md' "$INIT" | grep -F '"' | head -1)
if [ -z "$TIP" ]; then
  fail "the init's tip line" "no line in cadence-init.sh points at docs/install.md"
else
  TIPH=$(printf '%s\n' "$TIP" | sed -e 's/.*docs\/install.md[^"]*\\*"//' -e 's/\\*".*//')
  if [ -n "$TIPH" ] && grep -qF "# $TIPH" "$INSTALL"; then
    ok "the init's tip names a heading that exists (\"$TIPH\")"
  else
    fail "the init's tip heading" "cadence-init.sh sends the reader to \"$TIPH\", which docs/install.md does not carry as a heading"
  fi
fi

printf '\n== The CI step is spelled once ==\n'
CI_STEP=$(grep -oF '.githooks/orch-cadence-check.sh --audit HEAD' "$INSTALL" | head -1)
if [ -n "$CI_STEP" ]; then
  ok "docs/install.md carries the CI step: $CI_STEP"
  if grep -qF -- '--audit' "$INIT"; then
    grep -qF "$CI_STEP" "$INIT" \
      && ok "the init's recipe spells the CI step the same way" \
      || fail "the CI step's spelling" "cadence-init.sh mentions --audit but not \"$CI_STEP\""
  else
    fail "the init's CI recipe" "docs/install.md documents \"$CI_STEP\" but cadence-init.sh prints no --audit step at all, so nobody who follows the init is ever told to run it"
  fi
else
  fail "the CI step" "docs/install.md does not carry the one-line --audit step"
fi

printf '\n== The evidence page is linked and present ==\n'
[ -f "$ROOT/docs/cadence-evidence.md" ] && ok "docs/cadence-evidence.md exists" \
  || fail "docs/cadence-evidence.md" "the README links an evidence page that is not there"
has "$README" "docs/cadence-evidence.md" && ok "the README links the evidence page" \
  || fail "the README's evidence link" "the cadence section links nothing"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%d cadence doc checks passed.\n' "$PASS"; exit 0
else
  printf '%d passed, %d failed.\n' "$PASS" "$FAIL"; exit 1
fi
