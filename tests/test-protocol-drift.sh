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
#        - orch-proportional-reminder — SessionStart's post-compaction core
#        - orch-proportional-nudge    — UserPromptSubmit's every-turn
#                                       distillation, capped at its byte
#                                       ceiling so it cannot re-bloat into a
#                                       second copy of the recovery core
#      Both are injected only in a project whose cadence.json is enabled.
#   3. the using-orchestrator FORMAT block and output-styles/orchestrator.md
#      carry the six headers and the Verify: hard rule; the always-injected
#      EAGER core carries none of it
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
# Each shape must have its own numbered `### N. <Shape>` section heading. A
# bare-word grep could never fail: every shape word also appears in prose (the
# intro, cross-references), so deleting an entire section — verified with
# "### 3. Blocked" — left this check green. The heading is the definition; the
# word is not.
missing=""
for h in $HEADERS; do
  grep -qE "^### [0-9]+\. ${h%:}( |$)" "$CANON" || missing="$missing $h"
done
[[ -z "$missing" ]] && ok "canonical defines all six shapes (numbered section headings)" || fail "canonical shapes" "no '### N. <shape>' heading for:$missing"
grep -q 'DONE | DONE_WITH_CONCERNS | PARTIAL | BLOCKED | NEEDS_CONTEXT' "$CANON" \
  && ok "canonical Status enum includes PARTIAL" || fail "canonical enum" "PARTIAL missing from enum line"

printf '\n%s== post-compaction recovery core is single-sourced ==%s\n' "$DIM" "$RESET"
BLOCK=$(awk '/<!-- orch-proportional-reminder-start -->/{f=1;next} /<!-- orch-proportional-reminder-end -->/{f=0} f' "$CANON")
[[ -n "$BLOCK" ]] && ok "canonical carries the marked recovery-core block" || fail "recovery core block" "markers missing or empty"
for h in $HEADERS; do printf '%s' "$BLOCK" | grep -q "\"$h\"" || { fail "recovery core headers" "recovery block missing \"$h\""; break; }; done
printf '%s' "$BLOCK" | grep -q 'Verification: PASS|PENDING|BLOCKED|NOT APPLICABLE' && ok "recovery core states the completion vocabulary" || fail "recovery vocabulary" "missing"
# session-start.sh's compact path is the only consumer; it must read this marker.
grep -q 'orch-proportional-reminder' "${ROOT}/scripts/hooks/session-start.sh" \
  && ok "session-start.sh compact path reads the recovery core" \
  || fail "compact path wiring" "session-start.sh no longer extracts orch-proportional-reminder"
for m in orch-turn-reminder orch-turn-nudge; do
  if grep -q "$m" "$CANON" "${ROOT}/scripts/hooks/session-start.sh" "${ROOT}/scripts/hooks/user-prompt-submit.sh"; then
    fail "no second reply format" "$m is still named"; else ok "no $m block or reader is left"; fi
done

printf '\n%s== per-turn nudge is single-sourced and stays small ==%s\n' "$DIM" "$RESET"
# The ceiling is the per-turn budget. The nudge is paid on every turn in a
# cadence-enabled project, so it may not grow past it.
PNUDGE_MAX=273
PNUDGE=$(awk '/<!-- orch-proportional-nudge-start -->/{f=1;next} /<!-- orch-proportional-nudge-end -->/{f=0} f' "$CANON")
[[ -n "$PNUDGE" ]] && ok "canonical carries the marked turn-nudge block" || fail "nudge block" "markers missing or empty"
for h in $HEADERS; do printf '%s' "$PNUDGE" | grep -q "\"$h\"" || { fail "nudge headers" "nudge block missing \"$h\""; break; }; done
PBYTES=$(printf '%s' "$PNUDGE" | wc -c | tr -d ' ')
if (( PBYTES <= PNUDGE_MAX )); then
  ok "nudge stays within its per-turn budget (${PBYTES} <= ${PNUDGE_MAX} bytes)"
else
  fail "nudge budget" "${PBYTES} bytes exceeds the ${PNUDGE_MAX}-byte ceiling — trim it or move the text to the using-orchestrator eager block"
fi
[[ "$PNUDGE" != "$BLOCK" ]] && ok "nudge is a distillation, not a copy of the recovery core" \
  || fail "nudge duplication" "the per-turn block is byte-identical to the post-compaction core"
printf '%s' "$PNUDGE" | grep -q 'systematic-debugging' \
  && fail "nudge scope creep" "skill precedence belongs in the using-orchestrator eager block, not on every turn" \
  || ok "nudge carries no skill-routing text (that lives in the eager block)"
printf '%s' "$PNUDGE" | grep -q 'applicability never clears failed or required checks' \
  && ok "nudge says applicability never clears failed or required checks" \
  || fail "nudge applicability" "missing"
printf '%s' "$PNUDGE" | grep -q 'unless project instructions set a reply format' \
  && ok "nudge yields to the project's own reply format" || fail "nudge project format" "missing"

# Hook output (canonical present) vs hook output (canonical hidden → fallback)
# must be identical — the embedded fallback may not drift from the source.
extract_ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
mkdir -p "$TMP/x/hooks" "$TMP/x/lib"
cp "${ROOT}/scripts/hooks/user-prompt-submit.sh" "$TMP/x/hooks/"
cp "${ROOT}/scripts/lib/orch-protocol.sh" "${ROOT}/scripts/lib/orch-project.sh" "$TMP/x/lib/"

printf '\n%s== the reminders use actual project policy ==%s\n' "$DIM" "$RESET"
mkdir -p "$TMP/project/docs/llm-orchestrator"
printf '{"enabled":true,"workflow":"proportional"}\n' > "$TMP/project/docs/llm-orchestrator/cadence.json"
PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"prompt":"x"}))' "$TMP/project")
PLIVE=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$TMP/project" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/user-prompt-submit.sh" | extract_ctx)
PFALLBACK=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$TMP/project" ORCH_HOME="$TMP/home" bash "$TMP/x/hooks/user-prompt-submit.sh" | extract_ctx)
[[ "$PLIVE" == "$PNUDGE" && "$PFALLBACK" == "$PNUDGE" ]] && ok "the live nudge and the installed fallback both match canonical" || fail "reminder drift" "$PLIVE / $PFALLBACK"
PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"source":"compact"}))' "$TMP/project")
PCOMPACT=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$TMP/project" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/session-start.sh" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
if printf '%s' "$PCOMPACT" | grep -q 'Verification: PASS|PENDING|BLOCKED|NOT APPLICABLE' && ! printf '%s' "$PCOMPACT" | grep -q 'REQUIRE a "Verify:"'; then
  ok "compaction uses the shared completion vocabulary"
else fail "compaction vocabulary" "$PCOMPACT"; fi

printf '\n%s== an enabled cadence without "workflow": "proportional" is an error, not a format ==%s\n' "$DIM" "$RESET"
# SCENE: an enabled cadence.json with no workflow, or with "legacy"; when a
# session starts and a prompt is sent; expect no reply-format rule and no
# nudge, and a session-start verdict that names the one-line fix.
for WV in none legacy; do
  WD="$TMP/wf-$WV"; mkdir -p "$WD/docs/llm-orchestrator"
  if [[ "$WV" == "none" ]]; then printf '{"enabled": true}\n' > "$WD/docs/llm-orchestrator/cadence.json"
  else printf '{"enabled": true, "workflow": "legacy"}\n' > "$WD/docs/llm-orchestrator/cadence.json"; fi
  PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"prompt":"x"}))' "$WD")
  RAW=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$WD" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/user-prompt-submit.sh")
  [[ -z "$RAW" ]] && ok "workflow ${WV}: the per-turn hook injects nothing" || fail "workflow ${WV}: per-turn hook" "$RAW"
  for src in startup compact; do
    PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"source":sys.argv[2]}))' "$WD" "$src")
    CTX=$(printf '%s' "$PIN" | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$WD" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/session-start.sh" | extract_ctx)
    if printf '%s' "$CTX" | grep -q 'needs "workflow": "proportional"' \
       && ! printf '%s' "$CTX" | grep -qE 'Changed:|Verification: PASS|shape header'; then
      ok "workflow ${WV}: session start (${src}) names the fix and carries no reply-format rule"
    else fail "workflow ${WV}: session start (${src})" "$(printf '%s' "$CTX" | head -3)"; fi
  done
done

printf '\n%s== a project without an enabled cadence gets no format rule ==%s\n' "$DIM" "$RESET"
mkdir -p "$TMP/plain"
printf '{"enabled":false,"workflow":"proportional"}\n' > "$TMP/project/docs/llm-orchestrator/cadence.json"
for proj in "$TMP/project" "$TMP/plain"; do
  label="disabled cadence"; [[ "$proj" == "$TMP/plain" ]] && label="no cadence.json"
  PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"prompt":"x"}))' "$proj")
  RAW=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$proj" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/user-prompt-submit.sh")
  [[ -z "$RAW" ]] && ok "${label}: the per-turn hook injects nothing" || fail "${label}: per-turn hook" "$RAW"
  for src in startup compact; do
    PIN=$(python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"source":sys.argv[2]}))' "$proj" "$src")
    CTX=$(printf '%s' "$PIN" | CLAUDE_PROJECT_DIR="$proj" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/session-start.sh" | extract_ctx)
    if printf '%s' "$CTX" | grep -qE 'Changed:|Verification: PASS|shape header'; then
      fail "${label}: session start (${src}) carries no reply-format rule" "$(printf '%s' "$CTX" | grep -m1 -E 'Changed:|Verification: PASS|shape header')"
    else
      ok "${label}: session start (${src}) carries no reply-format rule"
    fi
  done
done

printf '\n%s== both hooks decide "enabled" the same way ==%s\n' "$DIM" "$RESET"
# session-start.sh and user-prompt-submit.sh share orch_protocol_workflow. Each
# case below must give the same answer from both: the per-turn nudge appears
# exactly when the session-start reply-format block does.
FORMAT_MARK='## Reply format in a cadence-enabled project'
both_hooks() { # <label> <project-dir> <expect on|off> [PATH override]
  local label="$1" dir="$2" want="$3" path="${4:-$PATH}" raw ctx turn=off start=off
  raw=$(printf '{"prompt":"x"}' | ( cd "$dir" && env PATH="$path" CLAUDE_PROJECT_DIR="$dir" ORCH_HOME="$TMP/home" "$BASH" "${ROOT}/scripts/hooks/user-prompt-submit.sh" ))
  [[ -n "$raw" ]] && turn=on
  ctx=$(printf '{"source":"startup"}' | ( cd "$dir" && env PATH="$path" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$dir" ORCH_HOME="$TMP/home" "$BASH" "${ROOT}/scripts/hooks/session-start.sh" 2>/dev/null ) | extract_ctx)
  case "$ctx" in *"$FORMAT_MARK"*) start=on ;; esac
  if [[ "$turn" == "$want" && "$start" == "$want" ]]; then
    ok "${label}: per-turn and session start both ${want}"
  else
    fail "${label}: hooks agree (${want})" "per-turn=${turn} session-start=${start}"
  fi
}
MALFORMED="$TMP/malformed"; mkdir -p "$MALFORMED/docs/llm-orchestrator"
printf '{"enabled": true, "workflow": "proportional",\n' > "$MALFORMED/docs/llm-orchestrator/cadence.json"
both_hooks "malformed cadence.json" "$MALFORMED" off
MCTX=$(printf '{"source":"startup"}' | ( cd "$MALFORMED" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$MALFORMED" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/session-start.sh" ) | extract_ctx)
case "$MCTX" in *"does not decode"*) ok "malformed cadence.json: the session-start verdict still reports the error" ;;
  *) fail "malformed verdict" "$(printf '%s' "$MCTX" | head -1)" ;; esac
REPO="$TMP/repo"; mkdir -p "$REPO/docs/llm-orchestrator" "$REPO/sub/dir"
git -C "$REPO" init -q
printf '{"enabled": true, "workflow": "proportional"}\n' > "$REPO/docs/llm-orchestrator/cadence.json"
both_hooks "launched from a subdirectory of an enabled repo" "$REPO/sub/dir" on
NOPY="$TMP/nopy"; mkdir -p "$NOPY"
for t in bash sh grep sed awk head tail cat dirname basename git mkdir ls tr cut cmp wc date find sort uname mktemp rm env comm shasum sha256sum openssl od; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOPY/$t"
done
ENABLED2="$TMP/enabled2"; mkdir -p "$ENABLED2/docs/llm-orchestrator"
printf '{"enabled": true, "workflow": "proportional"}\n' > "$ENABLED2/docs/llm-orchestrator/cadence.json"
both_hooks "python3 missing, enabled project" "$ENABLED2" on "$NOPY"
both_hooks "python3 missing, plain project" "$TMP/plain" off "$NOPY"

printf '\n%s== every hook finds the same cadence ==%s\n' "$DIM" "$RESET"
# One rule decides where the cadence lives (orch_cadence_find). Session start,
# the per-turn hook and the cadence stop hook must all see
# the cadence on, or all see it off, for the same CLAUDE_PROJECT_DIR.
every_hook() { # <label> <CLAUDE_PROJECT_DIR> <expect on|off>
  local label="$1" dir="$2" want="$3" got="" h rc out
  out=$(printf '{"prompt":"x"}' | ( cd "$dir" && CLAUDE_PROJECT_DIR="$dir" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/user-prompt-submit.sh" ))
  [[ -n "$out" ]] && got="${got} turn=on" || got="${got} turn=off"
  out=$(printf '{"source":"startup"}' | ( cd "$dir" && CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$dir" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/session-start.sh" ) | extract_ctx)
  case "$out" in *"$FORMAT_MARK"*) got="${got} start=on" ;; *) got="${got} start=off" ;; esac
  out=$(printf '{"session_id":"s"}' | ( cd "$dir" && CLAUDE_PROJECT_DIR="$dir" ORCH_HOME="$TMP/home" bash "${ROOT}/scripts/hooks/orch-cadence-stop.sh" 2>/dev/null ))
  [[ -n "$out" ]] && got="${got} stop=on" || got="${got} stop=off"
  if [[ "$got" == " turn=${want} start=${want} stop=${want}" ]]; then
    ok "${label}: every hook sees the cadence ${want}"
  else
    fail "${label}: every hook agrees (${want})" "$got"
  fi
}
MONO="$TMP/mono"; mkdir -p "$MONO/app/docs/llm-orchestrator" "$MONO/app/src" "$MONO/other"
git -C "$MONO" init -q
printf '{"enabled": true, "workflow": "proportional"}\n' > "$MONO/app/docs/llm-orchestrator/cadence.json"
every_hook "monorepo, cadence project nested at app/" "$MONO/app" on
every_hook "monorepo, launched from app/src" "$MONO/app/src" on
every_hook "monorepo, a sibling project without a cadence" "$MONO/other" off
every_hook "monorepo top level (the cadence is below it)" "$MONO" off
every_hook "repository launched from a subdirectory" "$REPO/sub/dir" on
every_hook "repository top level" "$REPO" on
# Outside any git repository only the start directory counts: a stray
# cadence.json in a home directory must not switch on every folder below it.
NOGIT="$TMP/nogit-home"; mkdir -p "$NOGIT/docs/llm-orchestrator" "$NOGIT/work/proj"
printf '{"enabled": true, "workflow": "proportional"}\n' > "$NOGIT/docs/llm-orchestrator/cadence.json"
every_hook "no git: a folder below a stray cadence.json" "$NOGIT/work/proj" off
every_hook "no git: the folder that holds the cadence.json" "$NOGIT" on

printf '\n%s== the two other carrier surfaces stay aligned ==%s\n' "$DIM" "$RESET"
CORE=$(awk '/<!-- ORCH:EAGER:START -->/{f=1;next} /<!-- ORCH:EAGER:END -->/{f=0} f' "${ROOT}/skills/using-orchestrator/SKILL.md")
FORMAT=$(awk '/<!-- ORCH:FORMAT:START -->/{f=1;next} /<!-- ORCH:FORMAT:END -->/{f=0} f' "${ROOT}/skills/using-orchestrator/SKILL.md")
for h in $HEADERS; do printf '%s' "$FORMAT" | grep -q "${h}" || { fail "skill format headers" "FORMAT block missing ${h}"; break; }; done
# Match the HARD-RULE SENTENCE, not the bare token: `Verify:` also appears in
# the sub-section list, so a token grep stayed green with the rule deleted —
# verified by removing the sentence and watching the tick persist.
printf '%s' "$FORMAT" | grep -q 'MUST include a `Verify:` line' && ok "using-orchestrator FORMAT block carries the six headers + Verify rule" || fail "skill format Verify" "the Changed:-requires-Verify: hard-rule sentence is missing from the FORMAT block"
printf '%s' "$FORMAT" | grep -q 'that format wins' && ok "FORMAT block says the project's own reply format wins" || fail "FORMAT project format" "missing"
# The EAGER core is injected in every project, so it must carry no reply-format rule.
printf '%s' "$CORE" | grep -qE '`(Changed|Found|Blocked|Issues|Plan):`' \
  && fail "EAGER core format-free" "the always-injected core names a reply header" \
  || ok "EAGER core (injected everywhere) names no reply header"
printf '%s' "$CORE" | grep -q 'Ordinary questions, explanations and small edits need no skill' \
  && ok "EAGER core says ordinary questions and small edits need no skill" \
  || fail "EAGER core skill rule" "the no-skill-needed sentence is missing"
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
# Without this field, choosing the style drops Claude Code's own instructions
# on scoping and verifying work.
grep -qx 'keep-coding-instructions: true' "$STYLE" && ok "output style keeps Claude Code's coding instructions" || fail "output style keep-coding-instructions" "missing"

printf '\n%s== Status enum consistent across consumers ==%s\n' "$DIM" "$RESET"
grep -q 'PARTIAL' "${ROOT}/scripts/lib/orch-protocol.sh" && ok "grader accepts PARTIAL" || fail "grader PARTIAL" "orch-protocol.sh"
grep -q 'Status: PARTIAL' "${ROOT}/templates/dispatch-response.md" && ok "dispatch-response documents PARTIAL" || fail "dispatch-response PARTIAL" ""
grep -q 'Status: PARTIAL' "${ROOT}/templates/implementer-prompt.md" && ok "implementer prompt documents PARTIAL" || fail "implementer-prompt PARTIAL" ""
# AGENTS.md is deliberately no longer a leg of this check: it was cut to the
# role table alone (126 -> 24 lines) because it loads into every session, and
# the enum stays single-sourced by the three consumers above.

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
