#!/usr/bin/env bash
# LLM Orchestrator research-gate hook (UserPromptSubmit).
# Deterministically detects when the user's message implies design work or a
# query that may touch a fast-moving library, version-specific API,
# security-sensitive domain, installed-version lookup, security advisory, or
# deprecation status — and compels the agent to invoke `research-classifier`
# before any spec or plan gets committed.
#
# This hook is the DETERMINISTIC half of the hybrid gate. It does not classify
# (that's the model's job); it just ensures the classifier runs when signals
# are present.
#
# Signal patterns live in scripts/lib/orch-signals.sh — the single source of
# truth shared with the classifier's smoke test. Drift between the two is
# caught by tests/test-research-gate.sh.
#
# Gated by ORCH_HOOK_PROFILE: skipped under minimal.
# Disabled if ORCH_DISABLED_HOOKS contains "orch-research-gate".
# Bash 3.2 compatible.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-research-gate,"* ]]; then
  exit 0
fi
if [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

# Load shared signal patterns. Single source of truth.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SIGNALS_FILE="${SCRIPT_DIR}/../lib/orch-signals.sh"
if [[ ! -f "${SIGNALS_FILE}" ]]; then
  # If shared signals are missing, the gate is broken — fail open (exit 0)
  # so we don't block user prompts, but the install --check will fail and
  # surface the missing file.
  echo "orch-research-gate: missing ${SIGNALS_FILE}; skipping" >&2
  exit 0
fi
# shellcheck disable=SC1090
source "${SIGNALS_FILE}"

# Read the hook event JSON from stdin.
INPUT=$(cat || true)

# Pull the user prompt text out of the JSON event. Tolerant of missing field.
PROMPT=$(printf '%s' "${INPUT}" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
         | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' \
         | head -1)

if [[ -z "${PROMPT}" ]]; then
  exit 0
fi

# Normalize to lowercase for matching (bash 3.2 compatible).
LOWER=$(printf '%s' "${PROMPT}" | tr '[:upper:]' '[:lower:]')

# Decision logic.
should_compel=0
matched_signal=""

# Explicit invocation wins.
if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_INVOCATION}"; then
  should_compel=1
  matched_signal="explicit /llm-orchestrator:research invocation"
fi

# Design intent + library/version/security mention → research-relevant.
if (( should_compel == 0 )); then
  if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_DESIGN_VERB}"; then
    if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY}"; then
      should_compel=1
      matched_signal="design verb + library mention"
    elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_VERSION}"; then
      should_compel=1
      matched_signal="design verb + version-shaped token"
    elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_SECURITY}"; then
      should_compel=1
      matched_signal="design verb + security-sensitive domain"
    fi
  fi
fi

# Architectural signal + library → also compel.
if (( should_compel == 0 )); then
  if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_ARCH}"; then
    if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY}"; then
      should_compel=1
      matched_signal="architectural signal + library mention"
    fi
  fi
fi

# Question-shape research — compel without a design verb.
if (( should_compel == 0 )); then
  if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_VERSION}"; then
    should_compel=1
    matched_signal="installed-version lookup"
  elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_ADVISORY}"; then
    should_compel=1
    matched_signal="security-advisory query"
  elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_DEPRECATION}"; then
    should_compel=1
    matched_signal="deprecation-status query"
  fi
fi

# Bail silently on no match — most user messages should fall here.
if (( should_compel == 0 )); then
  exit 0
fi

# ============================================================================
# Speculative priors lookup — Fix 1 (cache + config + declined_mcp reads)
# and Fix 2 (brief-index reads). Runs any time the sniffer compels. Reads
# only; nothing here mutates state. If the classifier later decides
# RESEARCH_SKIP, the injected priors are unused at zero runtime cost.
# This is the deterministic enforcement surface — the model cannot skip a
# hook the way it can skip a prompt-only instruction.
# ============================================================================

CACHE_HITS=""
BRIEF_HITS=""
RESEARCH_CONFIG=""
DECLINED_MCP=""

PROJECT_LIB="${SCRIPT_DIR}/../lib/orch-project.sh"
if [[ -f "${PROJECT_LIB}" ]]; then
  # shellcheck disable=SC1090
  source "${PROJECT_LIB}"
  HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  PROJECT_HASH=$(orch_project_hash 2>/dev/null || true)

  if [[ -n "${PROJECT_HASH}" ]]; then
    # Extract matched libraries from the (already lowercased) prompt.
    MATCHED_LIBS=""
    MATCHED_LIBS=$(printf '%s' "${LOWER}" | grep -oE "${ORCH_SIG_LIBRARY}" 2>/dev/null | sort -u || true)

    # ---- Fix 1: cache hits per matched library ----
    CACHE_DIR="${HOME_DIR}/research/cache/${PROJECT_HASH}"
    TTL_DAYS="${ORCH_RESEARCH_RETENTION_DAYS:-30}"
    if [[ -d "${CACHE_DIR}" && -n "${MATCHED_LIBS}" ]]; then
      while IFS= read -r lib; do
        [[ -z "${lib}" ]] && continue
        slug=$(orch_slugify "${lib}")
        [[ -z "${slug}" ]] && continue
        cache_file="${CACHE_DIR}/${slug}.md"
        if [[ -f "${cache_file}" ]]; then
          if find "${cache_file}" -mtime -"${TTL_DAYS}" -print 2>/dev/null | grep -q .; then
            mtime_date=$(orch_file_mtime_date "${cache_file}")
            CACHE_HITS="${CACHE_HITS}- ${lib}: ${cache_file} (retrieved ${mtime_date})"$'\n'
          fi
        fi
      done <<< "${MATCHED_LIBS}"
    fi

    # ---- Fix 2: brief-index hits per matched library ----
    INDEX_FILE="${HOME_DIR}/research/briefs-index/${PROJECT_HASH}.md"
    if [[ -f "${INDEX_FILE}" && -n "${MATCHED_LIBS}" ]]; then
      while IFS= read -r lib; do
        [[ -z "${lib}" ]] && continue
        slug=$(orch_slugify "${lib}")
        [[ -z "${slug}" ]] && continue
        # Index line format: <slug>|<outcome>|<YYYY-MM-DD>|<brief-path>
        entry=$(grep -E "^${slug}\|" "${INDEX_FILE}" 2>/dev/null | sort -t'|' -k3 -r | head -1 || true)
        if [[ -n "${entry}" ]]; then
          b_outcome=$(printf '%s' "${entry}" | cut -d'|' -f2)
          b_date=$(printf '%s' "${entry}" | cut -d'|' -f3)
          b_path=$(printf '%s' "${entry}" | cut -d'|' -f4)
          BRIEF_HITS="${BRIEF_HITS}- ${lib}: ${b_path} (${b_outcome}, ${b_date})"$'\n'
        fi
      done <<< "${MATCHED_LIBS}"
    fi

    # ---- Project memory: ## Research config section ----
    MEMORY_FILE="${HOME_DIR}/memory/${PROJECT_HASH}.md"
    if [[ -f "${MEMORY_FILE}" ]]; then
      CONFIG_BODY=$(awk '
        /^## Research config[[:space:]]*$/ { in_section=1; next }
        in_section && /^## / { in_section=0 }
        in_section { print }
      ' "${MEMORY_FILE}" 2>/dev/null || true)
      if [[ -n "${CONFIG_BODY}" ]]; then
        RESEARCH_CONFIG=$(printf '%s' "${CONFIG_BODY}" | grep -E 'research_aggressiveness|aggressiveness' | head -1 || true)
        DECLINED_MCP=$(printf '%s' "${CONFIG_BODY}" | grep -E 'declined_mcp:' || true)
      fi
    fi
  fi
fi

# ============================================================================
# Build guidance string. Lead with the always-emitted classifier instruction;
# append optional sections only when corresponding priors were found.
# ============================================================================

GUIDANCE="LLM Orchestrator research-gate detected potential research-relevant signals in this message (${matched_signal}). Before invoking brainstorming, writing-plans, or producing any spec/plan/approach, invoke the research-classifier skill against the task text. Act on its Status: RESEARCH_NEEDED or RESEARCH_SKIP output. If RESEARCH_NEEDED, dispatch orch-researcher and surface the brief BEFORE committing to an approach. If RESEARCH_SKIP, proceed normally — do not announce the skip."

if [[ -n "${RESEARCH_CONFIG}" ]]; then
  GUIDANCE="${GUIDANCE}

Research config (from project memory):
${RESEARCH_CONFIG}"
fi

if [[ -n "${CACHE_HITS}" ]]; then
  GUIDANCE="${GUIDANCE}

Cache priors (use if fresh; re-fetch only if the surface may have shifted since the retrieval date):
${CACHE_HITS%$'\n'}"
fi

if [[ -n "${BRIEF_HITS}" ]]; then
  GUIDANCE="${GUIDANCE}

Prior briefs (consult before re-researching the same surface; the researcher should verify the finding still holds or detect drift, not start from scratch):
${BRIEF_HITS%$'\n'}"
fi

if [[ -n "${DECLINED_MCP}" ]]; then
  GUIDANCE="${GUIDANCE}

Declined MCP nudges (do not re-nudge for these signal pairs):
${DECLINED_MCP}"
fi

# Native shell JSON escape (matches the SessionStart hook's pattern).
json_escape() {
  local s
  s=$(cat)
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  printf '"%s"' "${s}"
}

ESCAPED=$(printf '%s' "${GUIDANCE}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
