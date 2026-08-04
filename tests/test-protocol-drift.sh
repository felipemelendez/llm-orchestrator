#!/usr/bin/env bash
# Protocol single-source drift test.
#
# The Concise Agent Protocol is DEFINED once in concise-agent-protocol.md.
# Three other surfaces must carry it (each surface needs inline text — an
# output style, the SessionStart-injected skill core, the per-turn hook), and
# history shows they drift. This test pins them together:
#
#   1. canonical: six shapes + the full Status enum (incl. PARTIAL)
#   2. BOTH injected blocks are EXTRACTED from canonical marked blocks, and the
#      per-turn hook's embedded fallback is byte-identical to its source:
#        - orch-turn-reminder — SessionStart's post-compaction recovery core
#        - orch-turn-nudge    — UserPromptSubmit's every-turn distillation,
#                               capped at NUDGE_MAX bytes so it cannot re-bloat
#                               into a second copy of the recovery core
#   3. the using-orchestrator EAGER core and output-styles/orchestrator.md
#      carry the six headers and the Verify: hard rule
#   4. the Status enum is consistent across grader, templates, and AGENTS.md
#   5. CLAUDE.md references the canonical file instead of duplicating it
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANON="${ROOT}/concise-agent-protocol.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

HEADERS="Changed: Found: Blocked: Issues: Plan: Status:"

printf '%s== canonical file defines the protocol ==%s\n' "$DIM" "$RESET"
missing=""
for h in $HEADERS; do grep -q "${h%:}" "$CANON" || missing="$missing $h"; done
[[ -z "$missing" ]] && ok "canonical names all six shapes" || fail "canonical shapes" "missing:$missing"
grep -q 'DONE | DONE_WITH_CONCERNS | PARTIAL | BLOCKED | NEEDS_CONTEXT' "$CANON" \
  && ok "canonical Status enum includes PARTIAL" || fail "canonical enum" "PARTIAL missing from enum line"

printf '\n%s== post-compaction recovery core is single-sourced ==%s\n' "$DIM" "$RESET"
BLOCK=$(awk '/<!-- orch-turn-reminder-start -->/{f=1;next} /<!-- orch-turn-reminder-end -->/{f=0} f' "$CANON")
[[ -n "$BLOCK" ]] && ok "canonical carries the marked recovery-core block" || fail "recovery core block" "markers missing or empty"
for h in $HEADERS; do printf '%s' "$BLOCK" | grep -q "\"$h\"" || { fail "recovery core headers" "recovery block missing \"$h\""; break; }; done
printf '%s' "$BLOCK" | grep -q 'REQUIRE a "Verify:"' && ok "recovery core states the Verify: hard rule" || fail "recovery Verify rule" "missing"
# session-start.sh's compact path is the only consumer; it must read this marker.
grep -q 'orch-turn-reminder-start' "${ROOT}/scripts/hooks/session-start.sh" \
  && ok "session-start.sh compact path reads the recovery core" \
  || fail "compact path wiring" "session-start.sh no longer extracts orch-turn-reminder"

printf '\n%s== per-turn nudge is single-sourced and stays small ==%s\n' "$DIM" "$RESET"
NUDGE_MAX=300
NUDGE=$(awk '/<!-- orch-turn-nudge-start -->/{f=1;next} /<!-- orch-turn-nudge-end -->/{f=0} f' "$CANON")
[[ -n "$NUDGE" ]] && ok "canonical carries the marked turn-nudge block" || fail "nudge block" "markers missing or empty"
for h in $HEADERS; do printf '%s' "$NUDGE" | grep -q "\"$h\"" || { fail "nudge headers" "nudge block missing \"$h\""; break; }; done
printf '%s' "$NUDGE" | grep -q 'REQUIRES a "Verify:"' && ok "nudge states the Verify: hard rule" || fail "nudge Verify rule" "missing"
# The nudge is billed on EVERY turn. A byte ceiling is the only thing that stops
# it drifting back into a second copy of the recovery core, which is what the
# Claude 5 context-engineering guidance says to stop paying for.
NUDGE_BYTES=$(printf '%s' "$NUDGE" | wc -c | tr -d ' ')
if (( NUDGE_BYTES <= NUDGE_MAX )); then
  ok "nudge stays within its per-turn budget (${NUDGE_BYTES} <= ${NUDGE_MAX} bytes)"
else
  fail "nudge budget" "${NUDGE_BYTES} bytes exceeds the ${NUDGE_MAX}-byte ceiling — trim it or move the text to the using-orchestrator eager block"
fi
# The nudge must be a distillation, not the recovery core verbatim.
[[ "$NUDGE" != "$BLOCK" ]] && ok "nudge is a distillation, not a copy of the recovery core" \
  || fail "nudge duplication" "the per-turn block is byte-identical to the post-compaction core"
# The skill-precedence ordering moved to the SessionStart eager block (paid once)
# and must NOT come back per-turn.
printf '%s' "$NUDGE" | grep -q 'systematic-debugging' \
  && fail "nudge scope creep" "skill precedence belongs in the using-orchestrator eager block, not on every turn" \
  || ok "nudge carries no skill-routing text (that lives in the eager block)"

# Hook output (canonical present) vs hook output (canonical hidden → fallback)
# must be identical — the embedded fallback may not drift from the source.
extract_ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LIVE=$(printf '{"session_id":"drift-test","prompt":"x"}' | ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/user-prompt-submit.sh" | extract_ctx)
mkdir -p "$TMP/x/hooks"
cp "${ROOT}/scripts/hooks/user-prompt-submit.sh" "$TMP/x/hooks/"
FALLBACK=$(printf '{"session_id":"drift-test","prompt":"x"}' | ORCH_HOME="$TMP/home" bash "$TMP/x/hooks/user-prompt-submit.sh" | extract_ctx)
if [[ -n "$LIVE" && "$LIVE" == "$FALLBACK" ]]; then
  ok "hook fallback is byte-identical to the canonical block"
else
  fail "fallback drift" "the hook's embedded fallback differs from concise-agent-protocol.md's marked block — update the fallback"
fi
[[ "$LIVE" == "$NUDGE" ]] && ok "hook injects the canonical nudge verbatim" || fail "hook nudge" "hook output is not the marked nudge block"

printf '\n%s== the two other carrier surfaces stay aligned ==%s\n' "$DIM" "$RESET"
CORE=$(awk '/<!-- ORCH:EAGER:START -->/{f=1;next} /<!-- ORCH:EAGER:END -->/{f=0} f' "${ROOT}/skills/using-orchestrator/SKILL.md")
for h in $HEADERS; do printf '%s' "$CORE" | grep -q "${h}" || { fail "skill core headers" "EAGER core missing ${h}"; break; }; done
printf '%s' "$CORE" | grep -q 'Verify:' && ok "using-orchestrator EAGER core carries the six headers + Verify rule" || fail "skill core Verify" "missing"
# The precedence ordering left the per-turn hook; the eager block is now its only
# eagerly-loaded home. If it is not here, it is nowhere until the skill is read.
#
# Assert the ORDERING SENTENCE, not the skill names in it. `research-classifier`
# and `verification-before-completion` also appear in the trigger list a few
# clauses earlier, so a name-presence test passed even against the pre-change
# file that never carried the precedence rule at all — verified by restoring
# that file and watching the check still print a tick. An assertion that cannot
# fail is worse than none, because it is counted.
if printf '%s' "$CORE" | grep -q 'When two triggers match at once' \
   && printf '%s' "$CORE" | grep -qE 'process.*→.*implementation.*→.*verification'; then
  ok "EAGER core carries the skill-precedence ordering (moved off the per-turn hook)"
else
  fail "eager precedence" "the precedence ordering sentence is missing from the EAGER core"
fi
STYLE="${ROOT}/output-styles/orchestrator.md"
for h in $HEADERS; do grep -q "\`${h}\`" "$STYLE" || { fail "output style headers" "missing \`${h}\`"; break; }; done
grep -q 'Verify:' "$STYLE" && ok "output style carries the six headers + Verify rule" || fail "output style Verify" "missing"

printf '\n%s== Status enum consistent across consumers ==%s\n' "$DIM" "$RESET"
grep -q 'PARTIAL' "${ROOT}/scripts/lib/orch-protocol.sh" && ok "grader accepts PARTIAL" || fail "grader PARTIAL" "orch-protocol.sh"
grep -q 'Status: PARTIAL' "${ROOT}/templates/dispatch-response.md" && ok "dispatch-response documents PARTIAL" || fail "dispatch-response PARTIAL" ""
grep -q 'Status: PARTIAL' "${ROOT}/templates/implementer-prompt.md" && ok "implementer prompt documents PARTIAL" || fail "implementer-prompt PARTIAL" ""
grep -q 'PARTIAL' "${ROOT}/AGENTS.md" && ok "AGENTS.md documents PARTIAL" || fail "AGENTS.md PARTIAL" ""

printf '\n%s== CLAUDE.md references, never duplicates ==%s\n' "$DIM" "$RESET"
grep -q 'concise-agent-protocol.md' "${ROOT}/CLAUDE.md" && ok "CLAUDE.md points at the canonical file" || fail "CLAUDE.md reference" "missing"
grep -q '^## Shapes' "${ROOT}/CLAUDE.md" && fail "CLAUDE.md duplication" "CLAUDE.md re-defines the shapes" || ok "CLAUDE.md does not re-define the shapes"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-protocol-drift%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-protocol-drift — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
