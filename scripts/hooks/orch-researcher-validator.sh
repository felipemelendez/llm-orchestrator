#!/usr/bin/env bash
# LLM Orchestrator SubagentStop validator — enforcement teeth for orch-researcher.
#
# Fires when ANY subagent finishes (Claude Code does not filter by name in hook
# registration). We filter inside the script: only validate when the subagent
# was orch-researcher.
#
# The agent body forbids soft-pedaling a CONTRADICTED finding to COULDN'T_VERIFY.
# Smoke tests verify the rule is documented. THIS hook verifies the rule is
# obeyed at runtime: it reads the brief the agent wrote, compares the language
# against the declared Status outcome, and warns (or blocks) on mismatch.
#
# Heuristic checks (not perfect — false positives possible):
#   1. Status: VERIFIED but brief contains contradiction markers
#      ("deprecated", "removed", "renamed", "no longer", "✗ contradicted")
#   2. Status: COULDN'T_VERIFY but brief has the CONTRADICTED template format
#      ("Spec assumed:" + "Docs say:" + "Recommended revision:")
#   3. Status: CONTRADICTED but brief lacks the required Recommended revision section
#
# Modes:
#   default → warn to stderr (exit 0)
#   ORCH_STRICT_RESEARCH=1 → block (exit 2 with decision JSON)
#
# Gated by ORCH_HOOK_PROFILE: skipped under minimal.
# Disabled via ORCH_DISABLED_HOOKS containing "orch-researcher-validator".
# Bash 3.2 compatible.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
STRICT="${ORCH_STRICT_RESEARCH:-0}"

if [[ ",${DISABLED}," == *",orch-researcher-validator,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

INPUT=$(cat || true)

# Filter by subagent_type. Only validate orch-researcher.
SUBAGENT=$(printf '%s' "${INPUT}" | grep -oE '"subagent_type"[[:space:]]*:[[:space:]]*"[^"]*"' \
           | sed -E 's/.*"([^"]+)"$/\1/' | head -1)

if [[ "${SUBAGENT}" != "orch-researcher" ]]; then
  exit 0
fi

# Locate the transcript file.
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' \
             | sed -E 's/.*"([^"]+)"$/\1/' | head -1)

if [[ -z "${TRANSCRIPT}" || ! -f "${TRANSCRIPT}" ]]; then
  # Nothing to validate; pass through.
  exit 0
fi

# Read transcript tail (last 16 KB to catch the final Status block + any brief path).
TAIL=$(tail -c 16000 "${TRANSCRIPT}" 2>/dev/null || true)

# Extract the declared outcome from the Status block.
# Tolerant of literal newlines and JSONL-escaped \n.
OUTCOME=""
# Match Status: <OUTCOME> tolerantly. Don't anchor on whitespace — JSONL
# transcripts have `"content":"Status:` with no whitespace before. Use the
# most specific candidate first so VERIFIED doesn't accidentally match
# COULDN'T_VERIFY (it can't, but be explicit about order).
for candidate in CONTRADICTED "COULDN'T_VERIFY" NOT_APPLICABLE VERIFIED; do
  if printf '%s' "${TAIL}" | grep -qE 'Status:[[:space:]]*'"${candidate}"'(\\n|"|[[:space:]]|$)'; then
    OUTCOME="${candidate}"
    break
  fi
done

if [[ -z "${OUTCOME}" ]]; then
  # No recognized outcome — let SubagentStop's general validator handle it.
  exit 0
fi

# Find the brief path the agent wrote (or claimed to). Tolerant of JSONL.
BRIEF_PATH=$(printf '%s' "${TAIL}" | grep -oE 'Brief:[[:space:]]*[^\\"[:space:]]+\.md' \
             | sed -E 's/^Brief:[[:space:]]*//' | head -1)

if [[ -z "${BRIEF_PATH}" || ! -f "${BRIEF_PATH}" ]]; then
  # Researcher returned without a readable brief — that's already a problem,
  # but it's the SubagentStop general hook's job to flag missing Status.
  exit 0
fi

# Read the brief body.
BRIEF=$(cat "${BRIEF_PATH}" 2>/dev/null || true)
if [[ -z "${BRIEF}" ]]; then exit 0; fi

# Lowercase for matching.
BRIEF_LOWER=$(printf '%s' "${BRIEF}" | tr '[:upper:]' '[:lower:]')

MISMATCH=""

# Check 1: VERIFIED but brief contains contradiction markers.
if [[ "${OUTCOME}" == "VERIFIED" ]]; then
  # Strong contradiction signals — these mean the brief is talking about a
  # real API change that the Status outcome is suppressing.
  if printf '%s' "${BRIEF}" | grep -qE '✗[[:space:]]*contradicted'; then
    MISMATCH="brief contains '✗ contradicted' marker but Status says VERIFIED"
  elif printf '%s' "${BRIEF_LOWER}" | grep -qE '\b(deprecated since|removed in|renamed in|no longer exists|api[[:space:]]+removed|breaking change)\b'; then
    MISMATCH="brief language indicates a deprecation/removal/rename but Status says VERIFIED"
  fi
fi

# Check 2: COULDN'T_VERIFY but brief uses the CONTRADICTED template.
if [[ "${OUTCOME}" == "COULDN'T_VERIFY" ]]; then
  # All three of these together = CONTRADICTED template was filled in.
  if printf '%s' "${BRIEF}" | grep -qE '^\*\*Before\*\*' \
     && printf '%s' "${BRIEF}" | grep -qE '^\*\*After\*\*' \
     && printf '%s' "${BRIEF_LOWER}" | grep -qE 'recommended[[:space:]]+revision'; then
    MISMATCH="brief contains the Before/After + Recommended-revision pattern (CONTRADICTED template) but Status says COULDN'T_VERIFY — looks like a real contradiction got demoted"
  fi
fi

# Check 3: CONTRADICTED but brief lacks the required revision block.
if [[ "${OUTCOME}" == "CONTRADICTED" ]]; then
  if ! printf '%s' "${BRIEF_LOWER}" | grep -qE 'recommended[[:space:]]+revision'; then
    MISMATCH="Status says CONTRADICTED but brief lacks a Recommended revision section — first-class outcome requires it"
  fi
fi

# Check 4: NOT_APPLICABLE but brief lacks required Premise + Reality fields.
# Both fields are mandatory; without them the user can't see why the question didn't apply.
# Look for the actual structural markers (**Premise**, **Reality**, "Premise:", "Reality:")
# rather than the bare words — to avoid matching prose like "(no reality field)".
if [[ "${OUTCOME}" == "NOT_APPLICABLE" ]]; then
  has_premise=0; has_reality=0
  printf '%s' "${BRIEF}" | grep -qE '(\*\*Premise\*\*|^Premise:|^- Premise:)' && has_premise=1
  printf '%s' "${BRIEF}" | grep -qE '(\*\*Reality\*\*|^Reality:|^- Reality:)' && has_reality=1
  if (( has_premise == 0 )) || (( has_reality == 0 )); then
    missing=""
    (( has_premise == 0 )) && missing="Premise"
    (( has_reality == 0 )) && missing="${missing:+$missing + }Reality"
    MISMATCH="Status says NOT_APPLICABLE but brief lacks required field(s): ${missing}. Both Premise: and Reality: are mandatory for NOT_APPLICABLE briefs."
  fi
fi

# Check 5: NOT_APPLICABLE used as soft landing — brief contains real
# verification-attempt evidence (CONTRADICTED template markers or
# recommended-revision block). This is the anti-pattern the agent body
# explicitly forbids.
if [[ "${OUTCOME}" == "NOT_APPLICABLE" && -z "${MISMATCH}" ]]; then
  # If the brief has Before/After + recommended revision, or "Status: ✗ contradicted"
  # markers, the researcher likely did real verification and is mis-labeling.
  if printf '%s' "${BRIEF}" | grep -qE '✗[[:space:]]*contradicted'; then
    MISMATCH="Status says NOT_APPLICABLE but brief contains '✗ contradicted' markers — looks like a soft-pedaled CONTRADICTED. NOT_APPLICABLE is for premise-doesn't-hold cases only."
  elif printf '%s' "${BRIEF}" | grep -qE '^\*\*Before\*\*' \
       && printf '%s' "${BRIEF}" | grep -qE '^\*\*After\*\*' \
       && printf '%s' "${BRIEF_LOWER}" | grep -qE 'recommended[[:space:]]+revision'; then
    MISMATCH="Status says NOT_APPLICABLE but brief contains the Before/After + Recommended-revision pattern (CONTRADICTED template) — looks like a soft-pedaled CONTRADICTED."
  fi
fi

if [[ -z "${MISMATCH}" ]]; then
  # ===================================================================
  # Fix 1 + Fix 2 write enforcement (clean-outcome path only).
  # Runs only when no fidelity mismatch was detected — a mismatched brief
  # is questionable evidence and shouldn't be indexed for future priors.
  # NOT_APPLICABLE skipped: its Status block has no Libraries field, and
  # indexing the negative result is deferred until the real-work trace
  # shows it matters (would require a Libraries contract extension).
  # ===================================================================
  if [[ "${OUTCOME}" != "NOT_APPLICABLE" ]]; then
    PROJECT_LIB="$(dirname "$0")/../lib/orch-project.sh"
    LOCK_LIB="$(dirname "$0")/../lib/orch-lock.sh"
    if [[ -f "${PROJECT_LIB}" ]]; then
      # shellcheck disable=SC1090
      source "${PROJECT_LIB}"
      [[ -f "${LOCK_LIB}" ]] && source "${LOCK_LIB}"

      HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
      PROJECT_HASH=$(orch_project_hash 2>/dev/null || true)

      if [[ -n "${PROJECT_HASH}" ]]; then
        # Parse Libraries field — three variants per outcome:
        #   VERIFIED        → "Libraries verified: a, b, c"
        #   COULDN'T_VERIFY → "Libraries attempted: a, b, c"
        #   CONTRADICTED    → "Libraries: a, b, c"
        # JSONL escapes newlines to \n, so the field ends at \n or ".
        LIB_RAW=$(printf '%s' "${TAIL}" \
                  | grep -oE 'Libraries([[:space:]]+(verified|attempted))?:[[:space:]]*[^\\"]+' \
                  | head -1 \
                  | sed -E 's/^Libraries([[:space:]]+(verified|attempted))?:[[:space:]]*//' \
                  || true)
        LIB_RAW="${LIB_RAW%%\\n*}"
        LIB_RAW="${LIB_RAW%%\\\"*}"

        if [[ -n "${LIB_RAW}" ]]; then
          CACHE_DIR="${HOME_DIR}/research/cache/${PROJECT_HASH}"
          INDEX_DIR="${HOME_DIR}/research/briefs-index"
          INDEX_FILE="${INDEX_DIR}/${PROJECT_HASH}.md"
          mkdir -p "${INDEX_DIR}" 2>/dev/null || true

          TODAY=$(date +%Y-%m-%d 2>/dev/null || echo "unknown")

          MISSING_CACHE=""
          INDEX_ENTRIES=""

          LIBS_LIST=$(printf '%s' "${LIB_RAW}" | tr ',' '\n' \
                      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

          while IFS= read -r lib; do
            [[ -z "${lib}" ]] && continue
            slug=$(orch_slugify "${lib}")
            [[ -z "${slug}" ]] && continue
            # Cache write check (warn-only — strict mode is reserved for fidelity).
            cache_file="${CACHE_DIR}/${slug}.md"
            if [[ ! -f "${cache_file}" ]]; then
              MISSING_CACHE="${MISSING_CACHE}${lib} "
            fi
            # Index entry: <slug>|<outcome>|<YYYY-MM-DD>|<brief-path>
            INDEX_ENTRIES="${INDEX_ENTRIES}${slug}|${OUTCOME}|${TODAY}|${BRIEF_PATH}"$'\n'
          done <<< "${LIBS_LIST}"

          # Append index entries under lock (concurrent SubagentStop races
          # possible if multiple researchers fire in parallel).
          if [[ -n "${INDEX_ENTRIES}" ]]; then
            if command -v with_lock >/dev/null 2>&1; then
              with_lock "${INDEX_FILE}" bash -c 'printf "%s" "$1" >> "$2"' _ "${INDEX_ENTRIES}" "${INDEX_FILE}"
            else
              printf '%s' "${INDEX_ENTRIES}" >> "${INDEX_FILE}"
            fi
          fi

          # Warn on missing cache writes — never block. The researcher should
          # have written cache per the agent prompt; missing files mean the
          # next pre-research lookup misses, breaking the compounding loop.
          if [[ -n "${MISSING_CACHE}" ]]; then
            echo "orch-researcher-validator: brief outcome ${OUTCOME} cites libraries (${MISSING_CACHE% }) but no cache file was written under ${CACHE_DIR}/. Next pre-research lookup will miss the cache for these libraries; the researcher prompt instructs cache writes for every library fetched fresh — check whether the write step was skipped." >&2
          fi
        fi
      fi
    fi
  fi
  exit 0
fi

# Compose warning. Native shell JSON escape (no python3 dependency).
WARNING="orch-researcher-validator: Status/brief mismatch — ${MISMATCH}. Brief: ${BRIEF_PATH}. The CONTRADICTED outcome cannot be soft-pedaled into a softer Status; re-dispatch with explicit instruction to surface the contradiction."

json_escape() {
  local s; s=$(cat)
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}; s=${s//$'\b'/\\b}; s=${s//$'\f'/\\f}
  printf '"%s"' "${s}"
}

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-researcher-validator]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARNING}" >&2
  exit 0
fi

if [[ "${STRICT}" == "1" ]]; then
  ESCAPED=$(printf '%s' "${WARNING}" | json_escape)
  printf '{"decision":"block","reason":%s}\n' "${ESCAPED}"
  exit 2
fi

# Default: warn loudly to stderr, but don't block.
echo "${WARNING}" >&2
exit 0
