#!/usr/bin/env bash
# Protocol single-source drift test.
#
# The Concise Agent Protocol is DEFINED once in concise-agent-protocol.md.
# Three other surfaces must carry it (each surface needs inline text — an
# output style, the SessionStart-injected skill core, the per-turn hook), and
# history shows they drift. This test pins them together:
#
#   1. canonical: six shapes + the full Status enum (incl. PARTIAL)
#   2. the per-turn reminder is EXTRACTED from the canonical marked block, and
#      the hook's embedded fallback is byte-identical to it
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

printf '\n%s== per-turn reminder is single-sourced ==%s\n' "$DIM" "$RESET"
BLOCK=$(awk '/<!-- orch-turn-reminder-start -->/{f=1;next} /<!-- orch-turn-reminder-end -->/{f=0} f' "$CANON")
[[ -n "$BLOCK" ]] && ok "canonical carries the marked turn-reminder block" || fail "reminder block" "markers missing or empty"
for h in $HEADERS; do printf '%s' "$BLOCK" | grep -q "\"$h\"" || { fail "reminder headers" "reminder block missing \"$h\""; break; }; done
printf '%s' "$BLOCK" | grep -q 'REQUIRE a "Verify:"' && ok "reminder block states the Verify: hard rule" || fail "reminder Verify rule" "missing"

# Hook output (canonical present) vs hook output (canonical hidden → fallback)
# must be identical — the embedded fallback may not drift from the source.
extract_ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
LIVE=$(bash "${ROOT}/scripts/hooks/user-prompt-submit.sh" | extract_ctx)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/x/hooks"
cp "${ROOT}/scripts/hooks/user-prompt-submit.sh" "$TMP/x/hooks/"
FALLBACK=$(bash "$TMP/x/hooks/user-prompt-submit.sh" | extract_ctx)
if [[ -n "$LIVE" && "$LIVE" == "$FALLBACK" ]]; then
  ok "hook fallback is byte-identical to the canonical block"
else
  fail "fallback drift" "the hook's embedded fallback differs from concise-agent-protocol.md's marked block — update the fallback"
fi
printf '%s' "$LIVE" | grep -q 'LLM Orchestrator — every turn' && ok "hook injects the canonical reminder" || fail "hook reminder" "unexpected content"

printf '\n%s== the two other carrier surfaces stay aligned ==%s\n' "$DIM" "$RESET"
CORE=$(awk '/<!-- ORCH:EAGER:START -->/{f=1;next} /<!-- ORCH:EAGER:END -->/{f=0} f' "${ROOT}/skills/using-orchestrator/SKILL.md")
for h in $HEADERS; do printf '%s' "$CORE" | grep -q "${h}" || { fail "skill core headers" "EAGER core missing ${h}"; break; }; done
printf '%s' "$CORE" | grep -q 'Verify:' && ok "using-orchestrator EAGER core carries the six headers + Verify rule" || fail "skill core Verify" "missing"
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
