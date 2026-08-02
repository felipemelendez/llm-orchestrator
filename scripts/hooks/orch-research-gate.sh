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
# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# Pull the user prompt text out of the JSON event.
#
# It must be JSON-DECODED, not just grepped out. A grepped value keeps its
# escapes, so a newline stays as the two characters `\` and `n` — and `n` is a
# word character, which kills the `\b` anchor in every signal pattern below.
# The result: this gate saw only the first line of any prompt. A multi-line
# prompt (the normal shape of a spec, the exact case the gate exists for) went
# straight through. Measured before the fix: "add stripe checkout to the app"
# compelled; "Quick question.\nadd stripe checkout to the app" was silent.
#
# The grep path is kept as a fallback for a python3-less environment; it is the
# old, line-one-only behaviour, which is degraded but not wrong.
JSON_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}/../lib/orch-json.sh"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${JSON_LIB}" ]] && source "${JSON_LIB}"

PROMPT=""
declare -f orch_json_field >/dev/null 2>&1 && PROMPT=$(orch_json_field "${INPUT}" prompt)
if [[ -z "${PROMPT}" ]]; then
  PROMPT=$(printf '%s' "${INPUT}" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
           | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' \
           | head -1)
fi

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
    if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY}" \
       || printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY_STRUCTURAL}" \
       || printf '%s' "${PROMPT}" | grep -qE "${ORCH_SIG_LIBRARY_STRUCTURAL_DOTTED}"; then
      should_compel=1
      matched_signal="design verb + library mention"
    elif printf '%s' "${LOWER}" | sed -E "s/${ORCH_SIG_VERSION_NOISE}/ /g" | grep -qE "${ORCH_SIG_VERSION}"; then
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
    if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY}" \
       || printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LIBRARY_STRUCTURAL}" \
       || printf '%s' "${PROMPT}" | grep -qE "${ORCH_SIG_LIBRARY_STRUCTURAL_DOTTED}"; then
      should_compel=1
      matched_signal="architectural signal + library mention"
    fi
  fi
fi

# Package-manager or IaC direct invocation — compel without requiring a design verb.
# These are explicit tool commands, not natural language, so they carry enough
# signal on their own (e.g. "sam deploy ...", "npm install ...", "terraform plan").
if (( should_compel == 0 )); then
  # `npm` REQUIRES a dependency-changing subcommand. The subcommand group used
  # to be optional — `npm(\s+(i|install))?` — so the bare token `npm` compelled
  # a full research round trip, which meant `npm test` did, and `npm test` is
  # plausibly the most common thing a user types in this project. Only commands
  # that actually pull in or move a dependency carry research-worthy signal.
  PKG_MANAGER_DIRECT='\b(npm\s+(i|install|add|update|upgrade)|pnpm\s+(add|update)|yarn\s+(add|upgrade)|pip3?\s+install|poetry\s+add|cargo\s+add|go\s+get|gem\s+install|bundle\s+add|composer\s+require|apt(-get)?\s+install|brew\s+install)\b|\b(terraform|kubectl|helm|ansible|pulumi|cdk|serverless)\s+\w+|\baws\s+sam\s+\w+|\bsam\s+(build|deploy|init|local|package|publish|validate)\b'
  if printf '%s' "${LOWER}" | grep -qE "${PKG_MANAGER_DIRECT}"; then
    should_compel=1
    matched_signal="package-manager or IaC direct invocation"
  fi
fi

# Question-shape research — compel without a design verb.
if (( should_compel == 0 )); then
  if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_VERSION}"; then
    # Suppress when the subject is the orchestrator plugin itself — answerable
    # by reading on-disk files, not an upstream-docs question. Library lookups
    # ("what version of openssl is installed") are not self-referential and
    # still compel.
    if printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_LOCAL_SELF_LOOKUP}"; then
      : # local self-lookup — do not compel research
    else
      should_compel=1
      matched_signal="installed-version lookup"
    fi
  elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_ADVISORY}"; then
    should_compel=1
    matched_signal="security-advisory query"
  elif printf '%s' "${LOWER}" | grep -qE "${ORCH_SIG_QUESTION_DEPRECATION}"; then
    should_compel=1
    matched_signal="deprecation-status query"
  fi
fi

# REMOVED: the RESEARCH_UNCERTAIN notice.
#
# It fired when a design verb co-occurred with any capitalized token and a
# "structural hint" — but the hint list included `api`, `cli`, `plugin`,
# `module`, `server`, `adapter`, words that appear in most engineering
# requests, and the token was just the first capitalized word not on a ~40-word
# stop list. The comment above it promised that plain proper nouns "must NOT
# fire." Measured, they all did:
#
#   "implement the server that Felipe described" → possible library Felipe
#   "wire up the Bash tool guard in the plugin"  → possible library Bash
#   "add a CLI flag for verbose output"          → possible library CLI
#   "build the Monday report generator plugin"   → possible library Monday
#   "add caching to the API client"              → possible library API
#
# Every one of those told the agent to go research a library that does not
# exist. A notice that is wrong most of the time does not degrade to neutral —
# it teaches the agent to discount the channel, which costs the accurate
# compels that share it. The confident signals below (explicit library names,
# version tokens, package-manager invocations, advisory and deprecation
# queries) still fire; uncertainty is now silent.
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

GUIDANCE="LLM Orchestrator research-gate: signals detected (${matched_signal}). Before any spec, plan, or approach, invoke the research-classifier skill on the task text and act on its RESEARCH_NEEDED / RESEARCH_SKIP verdict. On RESEARCH_NEEDED, dispatch the research subagent and surface the brief before committing. On RESEARCH_SKIP, proceed silently."

if [[ -n "${RESEARCH_CONFIG}" ]]; then
  GUIDANCE="${GUIDANCE}

Research config (from project memory):
${RESEARCH_CONFIG}"
fi

if [[ -n "${CACHE_HITS}" ]]; then
  GUIDANCE="${GUIDANCE}

Cache priors (re-fetch only if the surface may have shifted):
${CACHE_HITS%$'\n'}"
fi

if [[ -n "${BRIEF_HITS}" ]]; then
  GUIDANCE="${GUIDANCE}

Prior briefs (verify still current; don't re-research from scratch):
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

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-research-gate]: would inject research-gate guidance (%s chars, signal: %s)\n' "${#GUIDANCE}" "${matched_signal}" >&2
  exit 0
fi

ESCAPED=$(printf '%s' "${GUIDANCE}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
