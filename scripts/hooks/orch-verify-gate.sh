#!/usr/bin/env bash
# LLM Orchestrator Stop hook — verification gate.
# Warns when the controller's final reply carries a `Changed:` block (code was
# edited) without real verification behind it. The verification-before-completion
# skill requires that evidence; this is the enforcement surface.
#
# HOW IT CHECKS. Not by trusting the reply, and not by asking the model to cite
# anything. The evidence-ledger PostToolUse hook records every verify-shaped
# command the harness actually executed; the UserPromptSubmit hook records when
# the turn began. This gate asks the ledger directly: "did a verify command run
# green, on real output, since this turn started?" The model is not in that loop
# — it cannot opt out by declining to cite, cannot reuse a stale green from an
# earlier turn, and never sees a marker or an instruction in its tool output.
# Stamp citation is still validated when present (ORCH_EVIDENCE_MARKER=1), but
# nothing depends on it.
#
# WHAT IT SAYS, AND WHEN IT STAYS QUIET.
#   HARD (blocks under ORCH_STRICT_VERIFY=1):
#   - the reply's Verify: block NAMES a verify-shaped command with no green
#     record of running this turn — the claim has no evidence behind it;
#   - a verify run this turn failed and was never re-run green;
#   - a cited stamp is fabricated or records a failure;
#   - a `Changed:` with no Verify: section at all.
#   SOFT (never blocks):
#   - the run was green but reported zero tests — exit 0 is not evidence.
#
# The first of those is what makes this a verification gate rather than a
# contradiction detector. Without it the gate could only ever say "your evidence
# is wrong", never "you have no evidence" — so a wholly invented Verify: block
# passed silently, warn AND strict, whenever the ledger happened to be empty.
#
# Absence stays SILENT only where we genuinely know nothing: a Verify: naming a
# command outside ORCH_SIG_VERIFY_CMD (a project's own script). Nagging those
# turns is how a gate teaches agents to tune it out. The regex is kept broad for
# exactly this reason — every runner it does not know is a turn this gate cannot
# check.
#
# Default: WARN-ONLY (stderr + additionalContext, exit 0). Set
# ORCH_STRICT_VERIFY=1 to block (exit 2) on the hard condition only; soft
# findings never block, under any setting.
#
# WIP escape (never fires on explicitly-marked in-progress work): skipped only
# when the working tree is dirty AND the last commit subject contains
# "wip"/"WIP". A dirty tree alone is the NORMAL mid-task state — an escape on
# dirty alone means the gate almost never fires (MAST FM-2.6); marking work WIP
# requires the commit subject to say so.
#
# Gated by ORCH_HOOK_PROFILE (skipped under minimal) and ORCH_DISABLED_HOOKS
# containing "orch-verify-gate". Honours ORCH_HOOK_DRY_RUN=1.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
# ORCH_HOOK_PROFILE=strict IMPLIES this flag. ARCHITECTURE.md has always
# documented `strict` as "all hooks active and blocking", but nothing branched
# on it — blocking came only from the explicit knob, so setting the profile
# bought the word and none of the behaviour. An explicit ORCH_STRICT_VERIFY=0
# still wins, so a per-check opt-out survives.
STRICT="${ORCH_STRICT_VERIFY:-0}"
if [[ -z "${ORCH_STRICT_VERIFY:-}" && "${ORCH_HOOK_PROFILE:-standard}" == "strict" ]]; then
  STRICT=1
fi

if [[ ",${DISABLED}," == *",orch-verify-gate,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  # Reuses the shared transcript extractor, which needs python3; degrade silently.
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${HOOK_DIR}/../lib/orch-protocol.sh"
[[ -f "${LIB}" ]] || exit 0
# shellcheck source=scripts/lib/orch-protocol.sh
source "${LIB}"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"
SIG_LIB="${HOOK_DIR}/../lib/orch-signals.sh"
# shellcheck source=scripts/lib/orch-signals.sh
[[ -f "${SIG_LIB}" ]] && source "${SIG_LIB}"
EV_LIB="${HOOK_DIR}/../lib/orch-evidence.sh"
# shellcheck source=scripts/lib/orch-evidence.sh
[[ -f "${EV_LIB}" ]] && source "${EV_LIB}"

# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# The reply comes from the stdin payload's last_assistant_message — the
# transcript is written asynchronously and may not yet hold this turn's final
# message; it is only the fallback for harnesses without the field.
REPLY=$(orch_reply_from_hook_input "${INPUT}" "${TRANSCRIPT}")
[[ -n "${REPLY}" ]] || exit 0

SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Scope to the protocol's hard rule: a `Changed:` block means code was edited and
# the verification-before-completion skill requires a `Verify:` line with it. This
# is high-precision — prose claims in Found:/Plan:/Status: replies ("I haven't
# fixed it", "still passing the wrong token") are not Changed: blocks and never
# fire. We deliberately do not keyword-match "done/fixed/passing" in free text.
# Two different questions need two different views of the reply.
#
# The CLAIM ("did this reply say Changed:") must ignore fenced content — a
# Found: reply quoting the protocol's own Changed: sample is not a claim.
#
# The EVIDENCE ("is there a Verify: section with content") must KEEP fenced
# content — pasting command output inside a ``` block is the normal, correct
# way to write a Verify: block, and dropping it would fail exactly the replies
# that did the best job.
REPLY_CLAIM=$(orch_strip_fenced "${REPLY}")
REPLY_EVID=$(printf '%s\n' "${REPLY}" | grep -v '^[[:space:]]*```')

# `**Changed:**` and `### Changed:` are the same claim. Anchoring on a bare
# `Changed:` let a bold or heading form skip the gate entirely, which meant
# the better-formatted reply was the one that escaped.
if ! printf '%s' "${REPLY_CLAIM}" | grep -qE '^[[:space:]]*(#{1,6}[[:space:]]*)?(\*\*)?Changed:'; then
  exit 0
fi

# Explicit cosmetic exemption, honoured before anything else can speak.
#
# SCOPED, because as a raw substring this was a model-controlled kill switch:
# the phrase anywhere in the reply — inside a code fence, quoted from the
# protocol doc, or in prose DISCLAIMING it ("this is not a case of no
# verification needed (cosmetic)") — silently disabled the gate, while the file
# claimed "the model is not in that loop. It cannot opt out."
#
# It is still an opt-out; that is intended and documented. What changes is that
# it must be USED rather than merely mentioned: the phrase has to appear
# outside code fences, on a line that reads as the Verify: line itself. Anyone
# wanting the exemption writes exactly what the protocol prescribes —
# `Verify: no verification needed (cosmetic)` — and prose about the phrase no
# longer counts as invoking it.
if printf '%s' "${REPLY_CLAIM}" \
   | grep -qE '^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}Verify[*_]{0,2}:[[:space:]]*[*_]{0,2}no verification needed \(cosmetic\)'; then
  exit 0
fi

# A Verify: section counts whether its content is on the same line or the next
# one — both are correct protocol. See orch_has_section.
#
# The HEADER must exist in the fence-stripped view (REPLY_CLAIM): a fenced
# block QUOTING `Verify: ./scripts/check.sh -> ok` is an example, not a
# section, but REPLY_EVID keeps fenced content, so measuring the header there
# scored a reply with NO real Verify: as having evidence — silent under warn
# AND strict. Section CONTENT is still measured against REPLY_EVID, so pasted
# output inside a fence under a real header keeps counting as evidence.
HAS_VERIFY=""
if printf '%s' "${REPLY_CLAIM}" \
   | grep -qE '^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}Verify[*_]{0,2}:'; then
  orch_has_section Verify "${REPLY_EVID}" && HAS_VERIFY=1
fi

WARN=""      # non-empty ⇒ speak
HARD=""      # non-empty ⇒ eligible to block under ORCH_STRICT_VERIFY=1

# --- 1. cited stamps (secondary; only when ORCH_EVIDENCE_MARKER=1 minted one)
if declare -f orch_evidence_check >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
  LEDGER=$(orch_evidence_ledger_path "${SESSION_ID}")
  # Fence-stripped, and with inline `backtick spans` removed: a reply that
  # DOCUMENTS the marker format (any turn editing scripts/lib/orch-evidence.sh)
  # was accused of citing a fabricated stamp. A quoted example is not a claim.
  _REPLY_NOCODE=$(printf '%s\n' "${REPLY_CLAIM}" | sed -E 's/`[^`]*`/ /g')
  EV_REASON=$(orch_evidence_check "${_REPLY_NOCODE}" "${LEDGER}")
  if [[ $? -eq 1 ]]; then
    HARD=1
    WARN="orch-verify-gate: ${EV_REASON} A Changed: claim requires green, hook-recorded verification. If the run genuinely failed, report Found: with the failure (the honest shape) instead of Changed: — do not simply re-run the same command hoping for green."
  fi
fi

# --- 2. a NAMED verify command with no record of running (primary)
if [[ -z "${WARN}" ]] && declare -f orch_evidence_unbacked_claim >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
  SINCE=$(orch_turn_start "${SESSION_ID}")
  UB_REASON=$(orch_evidence_unbacked_claim "${REPLY_EVID}" "${SESSION_ID}" "${SINCE}" "${ORCH_SIG_VERIFY_CMD:-}")
  if [[ $? -eq 1 ]]; then
    HARD=1
    WARN="orch-verify-gate: ${UB_REASON}. Run it and paste the real output, or report Found: with what actually happened. (If a subagent ran it, re-run it here — the controller's claim needs the controller's evidence.)"
  fi
fi

# --- 3. turn window
if [[ -z "${WARN}" ]] && declare -f orch_evidence_window >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
  SINCE=$(orch_turn_start "${SESSION_ID}")
  WIN_REASON=$(orch_evidence_window "${SESSION_ID}" "${SINCE}")
  case $? in
    1) HARD=1
       WARN="orch-verify-gate: ${WIN_REASON}. The reply claims Changed:, but the ledger records that run as failing. Report Found: with the failure (the honest shape) instead of Changed: — do not re-run the same command hoping for green." ;;
    3) WARN="orch-verify-gate (note): ${WIN_REASON}. An exit code of 0 is not evidence that anything was verified — a filter that matches no tests exits 0. Confirm the run covered the change before calling it done." ;;
    # 2 (nothing recorded) is deliberately silent — see the header.
  esac
fi

# --- 3b. red phase (soft; only when this turn touched a test file)
#
# A test that has never been seen failing has not been shown to test anything.
# Scoped deliberately: a docs, config or pure-refactor turn has no red phase to
# skip, so this only speaks when the working diff touches a test path. Soft by
# construction — the honest exceptions (a test that legitimately passes first
# because the behaviour already worked, a red run in an earlier turn) are real,
# and this is a prompt to think, not a verdict.
if [[ -z "${WARN}" ]] && declare -f orch_evidence_red_first >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
  PROJ="${CLAUDE_PROJECT_DIR:-${PWD}}"
  # Uncommitted changes AND anything committed since this turn began. Reading
  # only `git status` meant committing the test — which dispatching-subagents
  # requires — silenced the check, while a leftover dirty file from any earlier
  # turn fired it. Both halves are needed for "what this turn changed" to be true.
  _CHANGED=""
  if command -v git >/dev/null 2>&1 && git -C "${PROJ}" rev-parse --git-dir >/dev/null 2>&1; then
    # -uall: without it an untracked DIRECTORY is reported as `tests/` with no
    # filename to judge, and test-ness lives in the filename.
    _CHANGED=$(git -C "${PROJ}" status --porcelain -uall 2>/dev/null | sed -E 's/^.{3}//')
    _SINCE_TS=$(orch_turn_start "${SESSION_ID}")
    if [[ -n "${_SINCE_TS}" ]]; then
      _CHANGED="${_CHANGED}
$(git -C "${PROJ}" log --since="@${_SINCE_TS}" --name-only --pretty=format: 2>/dev/null)"
    fi
  fi
  if [[ -n "${_CHANGED}" ]] && orch_touches_tests "${_CHANGED}"; then
    SINCE=$(orch_turn_start "${SESSION_ID}")
    RP_REASON=$(orch_evidence_red_first "${SESSION_ID}" "${SINCE}")
    if [[ $? -eq 1 ]]; then
      WARN="orch-verify-gate (note): this turn changed a test file and ${RP_REASON}. A test that has never failed has not been shown to test anything — it may assert nothing, never execute, or mirror the implementation back at itself, and a green suite hides all three. If you did not watch it fail, run the test against the unfixed code once and confirm the failure message is the one you expect."
    fi
  fi
fi

# --- 4. no Verify: line at all
if [[ -z "${WARN}" && -z "${HAS_VERIFY}" ]]; then
  # WIP escape — only for work EXPLICITLY marked in progress: dirty tree AND a
  # wip commit subject. (Dirty alone is the normal mid-task state; escaping on
  # it alone means the gate never fires.)
  PROJ="${CLAUDE_PROJECT_DIR:-${PWD}}"
  if command -v git >/dev/null 2>&1 && git -C "${PROJ}" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git -C "${PROJ}" status --porcelain 2>/dev/null)" ]]; then
      _subj=$(git -C "${PROJ}" log -1 --pretty=%s 2>/dev/null || true)
      # Word-bounded: "wip: half done" and "[WIP] x" escape; "wipe cache" does not.
      if printf '%s' "${_subj}" | grep -qiE '(^|[^a-z])wip([^a-z]|$)'; then exit 0; fi
    fi
  fi
  # Hard: a Changed: with no Verify: at all is an unambiguous protocol
  # violation the agent can fix on the spot, so strict mode blocks it. Only the
  # substance note stays soft — it reports a judgement call, not a violation.
  HARD=1
  WARN="orch-verify-gate: this reply has a 'Changed:' block but no 'Verify:' line with evidence. The verification-before-completion skill requires the actual command and its output with any code change. Run the project's verify command (test/lint/typecheck) and include the result, mark the change cosmetic, or mark the work WIP (dirty tree + a 'wip' commit subject)."
fi

[[ -n "${WARN}" ]] || exit 0

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-verify-gate]: would %s — %s\n' \
    "$([[ "${STRICT}" == "1" && -n "${HARD}" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARN}" >&2
  exit 0
fi

ESC="$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
if [[ "${STRICT}" == "1" && -n "${HARD}" ]]; then
  # exit 2 feeds ONLY stderr back to the model — the reason goes there.
  printf '{"decision":"block","reason":%s}\n' "${ESC}" | tee /dev/stderr
  exit 2
fi

# Warn path: stderr for the user, additionalContext for the model.
echo "${WARN}" >&2
printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' "${ESC}"
exit 0
