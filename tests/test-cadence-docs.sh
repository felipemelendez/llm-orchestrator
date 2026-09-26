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
for m in --verdict --lock --commit-msg --audit --version; do
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

printf '\n== The lock set ==\n'
for n in "docs/llm-orchestrator/LAWS.md" "cadence.json" "LOCK.sha256" \
         ".githooks/commit-msg" ".githooks/orch-cadence-check.sh"; do
  if has "$SKILL" "$n" || has "$FULL" "$n"; then ok "$n in the skill's text"
  else fail "$n in the skill's text" "neither SKILL.md nor CADENCE.md names it"; fi
  has "$INSTALL" "$n" && ok "$n in docs/install.md" \
    || fail "$n in docs/install.md" "the install guide never spells it"
done

printf '\n== No legacy procedure is left ==\n'
# The legacy workflow was removed: a missing or "legacy" workflow is an error
# naming the one-line fix. What must not survive is text describing it.
for n in --landing CADENCE_STATE.md LEDGER.md notes_dir ticket_re HANDOFF_TEMPLATE.md \
         "Legacy procedure" "legacy procedure"; do
  if has "$SKILL" "$n" || has "$FULL" "$n"; then
    fail "$n is gone from the skill's text" "SKILL.md or CADENCE.md still names it"
  else ok "$n is gone from the skill's text"; fi
done
# The word "legacy" in shipped text is allowed only in the error that names the
# fix, in Codex's own name for its older history mode, and in a quote from
# Anthropic's guidance. Anything else describes the removed workflow.
LEG=$(grep -rIniw legacy "$ROOT/skills" "$ROOT/scripts" "$ROOT/commands" "$ROOT/agents" \
        "$ROOT/templates" "$ROOT/output-styles" "$ROOT/hooks" 2>/dev/null \
      | grep -v 'the legacy workflow was removed' | grep -v 'legacy-history' \
      | grep -v 'legacy harness scaffolding')
[ -z "$LEG" ] && ok "no shipped text describes a legacy workflow" \
  || fail "legacy text" "still written in: $(printf '%s\n' "$LEG" | cut -d: -f1,2 | tr '\n' ' ')"
# A seat's report reaches its caller through SubagentHandback in auto mode;
# "printed as your final message" alone never arrives there.
FM=$(grep -rIniE 'printed as (your|the) final message' "$ROOT/skills" "$ROOT/agents" \
       "$ROOT/templates" "$ROOT/commands" 2>/dev/null)
[ -z "$FM" ] && ok "no brief says the report is only printed as the final message" \
  || fail "final-message wording" "still written in: $(printf '%s\n' "$FM" | cut -d: -f1,2 | tr '\n' ' ')"

printf '\n== One wording for the workflow error ==\n'
# The error for a missing or other workflow is written in five places; each must
# carry the same sentence, and it must say the fix is a ruling once the project
# is armed (cadence.json is locked then).
WF_SENTENCE='needs "workflow": "proportional" (the legacy workflow was removed); add or fix that one line, through a ruling (cadence-ruling.sh) if the project is armed'
for f in skills/cadence/scripts/orch-cadence-check.sh skills/cadence/scripts/cadence-init.sh \
         skills/cadence/scripts/cadence-detect.sh \
         scripts/lib/orch-task-resources.py scripts/lib/orch-protocol.sh; do
  has "$ROOT/$f" "$WF_SENTENCE" && ok "$f carries the shared workflow error" \
    || fail "$f workflow error" "it does not carry: $WF_SENTENCE"
done

printf '\n== Every cadence reference is linked, and every link resolves ==\n'
REFS="$ROOT/skills/cadence/references"
for f in "$REFS"/*; do
  b=$(basename "$f")
  # Linked from the cadence skill's own pages, named by its full path, or read
  # by the init. A same-named file in another skill does not count.
  if grep -qF "(references/$b)" "$SKILL" "$FULL" 2>/dev/null \
     || grep -rqF "skills/cadence/references/$b" "$ROOT/skills" "$ROOT/commands" "$ROOT/scripts" 2>/dev/null \
     || grep -qF "\$REF_DIR/$b" "$INIT"; then ok "references/$b is read by the skill, a command or the init"
  else fail "references/$b" "nothing links or reads it"; fi
done
# Every relative link in the skill's two pages, the review briefs in
# requesting-code-review included, must name a file that exists.
for l in $(grep -ohE '\]\([^)#:]+' "$SKILL" "$FULL" | sed 's/^](//' | sort -u); do
  [ -f "$ROOT/skills/cadence/$l" ] && ok "$l exists" || fail "$l" "linked from the skill but missing"
done
# The review briefs are requesting-code-review's; the cadence keeps no copy.
for n in prover.md refuter.md security-lens.md; do
  has "$FULL" "../requesting-code-review/references/$n" && ok "CADENCE.md links the $n review brief" \
    || fail "the $n review brief" "CADENCE.md does not link ../requesting-code-review/references/$n"
done

printf '\n== Two layers, not three, and no deleted guard ==\n'
has "$INSTALL" "### $LOCK_HEADING" && ok "docs/install.md carries the heading \"$LOCK_HEADING\"" \
  || fail "the heading \"$LOCK_HEADING\"" "docs/install.md has no such section heading"
has "$README" "two layers" && ok "the README names the lock's two layers" \
  || fail "the README's two layers" "the cadence section does not say two layers"
SHIPPED="$ROOT/scripts $ROOT/hooks $ROOT/skills $ROOT/commands $ROOT/templates $ROOT/docs"
# docs/llm-orchestrator/scratch/ is git-ignored task scratch, never shipped.
SCRATCH="^$ROOT/docs/llm-orchestrator/scratch/"
# shellcheck disable=SC2086
THREE=$(grep -rlF "lock's three layers" $SHIPPED "$ROOT/README.md" "$ROOT/ARCHITECTURE.md" \
        "$ROOT/CHANGELOG.md" "$ROOT/AGENTS.md" 2>/dev/null | grep -v "$SCRATCH")
[ -z "$THREE" ] && ok "nothing shipped still says three layers" \
  || fail "three layers" "still written in: $THREE"
# shellcheck disable=SC2086
GONE=$(grep -rlF "guard-cadence-lock" $SHIPPED "$ROOT/README.md" "$ROOT/ARCHITECTURE.md" \
       "$ROOT/CHANGELOG.md" "$ROOT/AGENTS.md" 2>/dev/null | grep -v "$SCRATCH")
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
  printf '%d checks passed (cadence docs).\n' "$PASS"; exit 0
else
  printf '%d passed, %d failed.\n' "$PASS" "$FAIL"; exit 1
fi
