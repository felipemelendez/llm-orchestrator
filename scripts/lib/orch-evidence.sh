#!/usr/bin/env bash
# orch-evidence.sh — shared helpers for the verification evidence ledger.
#
# The ledger is written EXCLUSIVELY by the PostToolUse hook
# (orch-evidence-ledger.sh): one TSV line per verify-shaped Bash command the
# harness actually executed. Because the hook — not the model — computes and
# records the stamp, a stamp cited in a reply can be checked against recorded
# reality instead of trusted. This closes the fabrication path where the model
# writes a plausible `Verify:` line for a command it never ran (MAST FM-2.6,
# reasoning-action mismatch).
#
# Honest boundary: this defeats fabrication/hallucination, not a deliberately
# adversarial model — an agent with arbitrary shell could append to the ledger
# file itself. The threat here is a model that *narrates* verification it
# didn't do, and that model does not run multi-step ledger forgeries.
#
# Ledger line format (TSV):  <stamp>\t<exit>\t<epoch>\t<command-first-160>
# Ledger path:               ${ORCH_HOME}/state/<project-hash>/evidence.<session_id>.tsv
#
# Bash 3.2 compatible. No external deps beyond grep/awk/shasum-or-cksum.

# orch_evidence_ledger_path <session_id>
# Prints the ledger path for this project + session. Requires orch-project.sh
# to be sourced (for orch_project_hash); falls back to "default" hash.
orch_evidence_ledger_path() {
  local sid="$1" home hash
  home="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  hash="default"
  declare -f orch_project_hash >/dev/null 2>&1 && hash=$(orch_project_hash 2>/dev/null || echo default)
  printf '%s/state/%s/evidence.%s.tsv' "${home}" "${hash}" "${sid}"
}

# orch_evidence_stamp_of <text>
# Prints the first stamp hash cited in <text> ("[orch-evidence <hex> ...]"),
# or nothing.
orch_evidence_stamp_of() {
  printf '%s' "$1" | grep -oE '\[orch-evidence [0-9a-f]{8,40}' | head -1 | awk '{print $2}'
}

# orch_evidence_check <reply_text> <ledger_path>
# Validates the evidence stamps cited in a reply against the ledger.
# Prints a one-line reason on any non-zero return.
# Return codes:
#   0 — no problem (all cited stamps recorded with exit 0, or no ledger file:
#       the ledger hook is disabled, nothing to check against)
#   1 — HARD: a cited stamp is not in the ledger (fabricated), or is recorded
#       with a non-zero exit (the cited run actually FAILED)
#   2 — SOFT: no stamp cited, but the ledger file exists — the reply should
#       cite the [orch-evidence ...] line from the actual run
orch_evidence_check() {
  local reply="$1" ledger="$2" stamp line ec
  [[ -f "${ledger}" ]] || return 0

  stamp=$(orch_evidence_stamp_of "${reply}")
  if [[ -z "${stamp}" ]]; then
    printf 'no [orch-evidence <stamp>] cited — copy the stamp line the verify command printed into the Verify: block\n'
    return 2
  fi

  # Validate every cited stamp, not just the first.
  local all rc=0
  all=$(printf '%s' "${reply}" | grep -oE '\[orch-evidence [0-9a-f]{8,40}' | awk '{print $2}' | sort -u)
  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] || continue
    line=$(grep -m1 "^${stamp}	" "${ledger}" 2>/dev/null || true)
    if [[ -z "${line}" ]]; then
      printf 'stamp %s is not in the evidence ledger — no such verification run was recorded (fabricated or copied from another session)\n' "${stamp}"
      return 1
    fi
    ec=$(printf '%s' "${line}" | cut -f2)
    if [[ "${ec}" != "0" ]]; then
      printf 'stamp %s is recorded with exit=%s — the cited verification run FAILED\n' "${stamp}" "${ec}"
      return 1
    fi
  done <<< "${all}"
  return ${rc}
}
