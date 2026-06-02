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
# WIP escape (never fires on legitimately-incomplete work): skipped when the
# working tree is dirty, when on a non-default branch with uncommitted changes,
# or when the last commit subject contains "wip"/"WIP".
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

INPUT=$(cat || true)
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ -n "${TRANSCRIPT}" && -f "${TRANSCRIPT}" ]] || exit 0

REPLY=$(orch_extract_last_assistant_text "${TRANSCRIPT}")
[[ -n "${REPLY}" ]] || exit 0

# Scope to the protocol's hard rule: a `Changed:` block means code was edited and
# the verification-before-completion skill requires a `Verify:` line with it. This
# is high-precision — prose claims in Found:/Plan:/Status: replies ("I haven't
# fixed it", "still passing the wrong token") are not Changed: blocks and never
# fire. We deliberately do not keyword-match "done/fixed/passing" in free text.
if ! printf '%s' "${REPLY}" | grep -qE '^[[:space:]]*Changed:'; then
  exit 0
fi

# Is there verification evidence — a `Verify:` line with content after it?
if printf '%s' "${REPLY}" | grep -qE '^[[:space:]]*Verify:[[:space:]]*\S'; then
  exit 0
fi

# WIP escape — don't nag legitimately-incomplete work.
PROJ="${CLAUDE_PROJECT_DIR:-${PWD}}"
if command -v git >/dev/null 2>&1 && git -C "${PROJ}" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -n "$(git -C "${PROJ}" status --porcelain 2>/dev/null)" ]]; then
    exit 0  # dirty tree → work in progress
  fi
  _subj=$(git -C "${PROJ}" log -1 --pretty=%s 2>/dev/null || true)
  case "${_subj}" in
    *wip*|*WIP*|*Wip*) exit 0 ;;
  esac
fi

WARN="orch-verify-gate: this reply has a 'Changed:' block but no 'Verify:' line with evidence. The verification-before-completion skill requires the actual command and its output with any code change. Run the project's verify command (test/lint/typecheck) and include the result, or mark the work WIP."

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-verify-gate]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARN}" >&2
  exit 0
fi

if [[ "${STRICT}" == "1" ]]; then
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 2
fi

echo "${WARN}" >&2
exit 0
