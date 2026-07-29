#!/usr/bin/env bash
# LLM Orchestrator Stop hook — verification gate.
# Warns when the controller's final reply claims completion ("done", "fixed",
# "tests pass", "ready to merge") but carries no `Verify:` line with evidence.
# The verification-before-completion skill requires that evidence; this is the
# enforcement surface.
#
# Default: WARN-ONLY (stderr, exit 0). Set ORCH_STRICT_VERIFY=1 to block (exit 2).
# This ships warn-only deliberately — observe it for a release before any team
# flips the default.
#
# WIP escape (never fires on explicitly-marked in-progress work): skipped only
# when the working tree is dirty AND the last commit subject contains
# "wip"/"WIP". A dirty tree alone is the NORMAL mid-task state — an escape on
# dirty alone means the gate almost never fires (MAST FM-2.6); marking work WIP
# requires the commit subject to say so.
#
# Evidence ledger: when the orch-evidence-ledger PostToolUse hook is active,
# verify-shaped commands mint an "[orch-evidence <stamp> exit=N]" line that the
# reply is expected to cite. This gate validates cited stamps against the
# hook-written ledger: a stamp with no ledger entry (fabricated) or a non-zero
# exit (the cited run failed) warns — or blocks under ORCH_STRICT_VERIFY=1.
# A stampless Verify: while the ledger exists gets a soft nag only.
#
# Gated by ORCH_HOOK_PROFILE (skipped under minimal) and ORCH_DISABLED_HOOKS
# containing "orch-verify-gate". Honours ORCH_HOOK_DRY_RUN=1.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
STRICT="${ORCH_STRICT_VERIFY:-0}"

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
EV_LIB="${HOOK_DIR}/../lib/orch-evidence.sh"
# shellcheck source=scripts/lib/orch-evidence.sh
[[ -f "${EV_LIB}" ]] && source "${EV_LIB}"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"

INPUT=$(cat || true)
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ -n "${TRANSCRIPT}" && -f "${TRANSCRIPT}" ]] || exit 0

REPLY=$(orch_extract_last_assistant_text "${TRANSCRIPT}")
[[ -n "${REPLY}" ]] || exit 0

SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Scope to the protocol's hard rule: a `Changed:` block means code was edited and
# the verification-before-completion skill requires a `Verify:` line with it. This
# is high-precision — prose claims in Found:/Plan:/Status: replies ("I haven't
# fixed it", "still passing the wrong token") are not Changed: blocks and never
# fire. We deliberately do not keyword-match "done/fixed/passing" in free text.
if ! printf '%s' "${REPLY}" | grep -qE '^[[:space:]]*Changed:'; then
  exit 0
fi

# Is there verification evidence — a `Verify:` line with content after it?
HAS_VERIFY=""
printf '%s' "${REPLY}" | grep -qE '^[[:space:]]*Verify:[[:space:]]*\S' && HAS_VERIFY=1

WARN=""
if [[ -n "${HAS_VERIFY}" ]]; then
  # Verify: line present — validate any cited evidence stamp against the
  # hook-written ledger. Cosmetic exemption skips the stampless soft nag.
  if declare -f orch_evidence_check >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
    LEDGER=$(orch_evidence_ledger_path "${SESSION_ID}")
    EV_REASON=$(orch_evidence_check "${REPLY}" "${LEDGER}")
    EV_RC=$?
    if [[ ${EV_RC} -eq 1 ]]; then
      WARN="orch-verify-gate: ${EV_REASON} A Changed: claim requires green, hook-recorded verification. If the run genuinely failed, report Found: with the failure (the honest shape) instead of Changed: — do not simply re-run the same command hoping for green."
    elif [[ ${EV_RC} -eq 2 ]]; then
      case "${REPLY}" in
        *"no verification needed (cosmetic)"*) exit 0 ;;
      esac
      # Soft nag only — never blocks, even under strict: a stampless Verify:
      # may be a command outside the verify-shape regex.
      printf 'orch-verify-gate (note): %s\n' "${EV_REASON}" >&2
      exit 0
    fi
  fi
  [[ -z "${WARN}" ]] && exit 0
fi

if [[ -z "${WARN}" ]]; then
  # No Verify: at all. WIP escape — only for work EXPLICITLY marked in
  # progress: dirty tree AND a wip commit subject. (Dirty alone is the normal
  # mid-task state; escaping on it alone means the gate never fires.)
  PROJ="${CLAUDE_PROJECT_DIR:-${PWD}}"
  if command -v git >/dev/null 2>&1 && git -C "${PROJ}" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git -C "${PROJ}" status --porcelain 2>/dev/null)" ]]; then
      _subj=$(git -C "${PROJ}" log -1 --pretty=%s 2>/dev/null || true)
      # Word-bounded: "wip: half done" and "[WIP] x" escape; "wipe cache" does not.
      if printf '%s' "${_subj}" | grep -qiE '(^|[^a-z])wip([^a-z]|$)'; then exit 0; fi
    fi
  fi
  WARN="orch-verify-gate: this reply has a 'Changed:' block but no 'Verify:' line with evidence. The verification-before-completion skill requires the actual command and its output with any code change. Run the project's verify command (test/lint/typecheck) and include the result, or mark the work WIP (dirty tree + a 'wip' commit subject)."
fi

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-verify-gate]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARN}" >&2
  exit 0
fi

ESC="$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
if [[ "${STRICT}" == "1" ]]; then
  # exit 2 feeds ONLY stderr back to the model — the reason goes there.
  printf '{"decision":"block","reason":%s}\n' "${ESC}" | tee /dev/stderr
  exit 2
fi

# Warn path: stderr for the user, additionalContext for the model.
echo "${WARN}" >&2
printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' "${ESC}"
exit 0
