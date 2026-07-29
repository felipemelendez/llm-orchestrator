#!/usr/bin/env bash
# Validates that templates/research-brief.md has the required structure for
# all three first-class outcomes (VERIFIED, COULDN'T_VERIFY, CONTRADICTED),
# and that agents/orch-researcher.md matches the contract the brief defines.
#
# This is structural — content quality (whether actual research is accurate)
# requires real MCP calls and is tested in docs/manual-testing.md.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/templates/research-brief.md"
AGENT="$ROOT/agents/orch-researcher.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

must_grep() {
  local file="$1" pattern="$2" desc="$3"
  if grep -qE "$pattern" "$file"; then
    ok "$desc"
  else
    fail "$desc" "missing pattern: $pattern in $(basename "$file")"
  fi
}

# ============================================================
# Brief template structural checks
# ============================================================
printf '%s== Research brief template ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$TEMPLATE" ]]; then
  fail "Template exists" "$TEMPLATE not found"
else
  ok "Template exists"

  # All four outcomes must be documented
  must_grep "$TEMPLATE" 'VERIFIED' "Template documents VERIFIED outcome"
  must_grep "$TEMPLATE" "COULDN'T_VERIFY" "Template documents COULDN'T_VERIFY outcome"
  must_grep "$TEMPLATE" 'CONTRADICTED' "Template documents CONTRADICTED outcome"
  must_grep "$TEMPLATE" 'NOT_APPLICABLE' "Template documents NOT_APPLICABLE outcome (Fix 2)"
  must_grep "$TEMPLATE" '\*\*Premise\*\*' "Template has Premise field (required for NOT_APPLICABLE)"
  must_grep "$TEMPLATE" '\*\*Reality\*\*' "Template has Reality field (required for NOT_APPLICABLE)"

  # Required structural sections
  must_grep "$TEMPLATE" '^## Summary' "Template has Summary section"
  must_grep "$TEMPLATE" '^## What was verified' "Template has 'What was verified' section"
  must_grep "$TEMPLATE" 'Recommended revision' "Template has Recommended revision section (for CONTRADICTED)"
  must_grep "$TEMPLATE" '^## Sources' "Template has Sources section"
  must_grep "$TEMPLATE" '^## Notes' "Template has Notes section for sub-confidence observations"

  # Citation format: every example URL must have a retrieval date
  if grep -E '^- <URL>' "$TEMPLATE" | grep -vE '\(retrieved [0-9]{4}-[0-9]{2}-[0-9]{2}\)' >/dev/null; then
    fail "Citation date format" "found a URL example without (retrieved YYYY-MM-DD) tag"
  else
    ok "Every citation example carries a retrieval date"
  fi

  # CONTRADICTED severity field is required
  must_grep "$TEMPLATE" 'Severity:.*Critical.*Important' "CONTRADICTED severity (Critical/Important) documented"

  # Frontmatter must list Outcome as first-class
  must_grep "$TEMPLATE" '^Outcome:.*VERIFIED.*COULDN' "Template's frontmatter Outcome line lists all three"

  # Recommended revision must require Before/After (the copy-paste-ready format)
  must_grep "$TEMPLATE" '\*\*Before\*\*' "Recommended revision uses Before/After format (copy-paste-ready)"
  must_grep "$TEMPLATE" '\*\*After\*\*' "Recommended revision uses Before/After format (copy-paste-ready)"
fi

# ============================================================
# orch-researcher agent structural checks
# ============================================================
printf '\n%s== orch-researcher agent ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$AGENT" ]]; then
  fail "Agent exists" "$AGENT not found"
else
  ok "Agent exists"

  # Frontmatter — match the validator's expectations
  must_grep "$AGENT" '^name: orch-researcher$' "Frontmatter name matches filename"
  must_grep "$AGENT" '^model: opus$' "Model is opus (fresher knowledge cutoff than fable)"
  # Effort must NOT be pinned: agents inherit the session preference (HAL found
  # higher effort reduced accuracy in most runs; Anthropic says effort is a
  # general preference, and pinning would override the user's session choice).
  if grep -q '^effort: ' "$AGENT"; then
    fail "Effort is not pinned (inherits session)" "found a pinned effort: line"
  else
    ok "Effort is not pinned (inherits session)"
  fi
  must_grep "$AGENT" '^tools:.*WebFetch' "Agent has WebFetch tool"
  must_grep "$AGENT" '^tools:.*WebSearch' "Agent has WebSearch tool"
  must_grep "$AGENT" '^tools:.*Read' "Agent has Read tool"
  must_grep "$AGENT" '^tools:.*Write' "Agent has Write tool (for brief artifact)"

  # All four outcomes must be honored
  must_grep "$AGENT" 'Status: VERIFIED' "Agent documents VERIFIED status"
  must_grep "$AGENT" 'Status: COULDN'"'"'T_VERIFY' "Agent documents COULDN'T_VERIFY status"
  must_grep "$AGENT" 'Status: CONTRADICTED' "Agent documents CONTRADICTED status"
  must_grep "$AGENT" 'Status: NOT_APPLICABLE' "Agent documents NOT_APPLICABLE status (Fix 2)"
  if grep -qE 'soft-pedaling.*COULDN.*NOT_APPLICABLE|CONTRADICTED.*COULDN.*NOT_APPLICABLE.*soft' "$AGENT" \
     || grep -qE 'Soft-pedaling.*CONTRADICTED.*COULDN.*NOT_APPLICABLE' "$AGENT"; then
    ok "Agent forbids soft-pedaling into NOT_APPLICABLE (anti-pattern documented)"
  else
    fail "Anti-soft-pedal-NA rule" "agent must explicitly forbid demoting CONTRADICTED/COULDN'T_VERIFY into NOT_APPLICABLE"
  fi

  # The contradicted-is-first-class invariant — the user named this as the
  # most important property. Test that the agent body says it explicitly.
  if grep -qE 'first-class|do not soft-pedal|halts the workflow' "$AGENT"; then
    ok "Agent treats CONTRADICTED as first-class (halt, not soft-warn)"
  else
    fail "CONTRADICTED first-class invariant" "agent body must explicitly say CONTRADICTED halts, not soft-warns"
  fi

  # Anti-soft-pedal: explicit warning against demoting CONTRADICTED → COULDN'T_VERIFY
  if grep -qE 'Soft-pedaling|soft-pedal|wave.*past|wave a CONTRADICTED' "$AGENT"; then
    ok "Agent forbids soft-pedaling CONTRADICTED"
  else
    fail "Anti-soft-pedal rule" "agent must forbid demoting CONTRADICTED to a softer outcome"
  fi

  # Citation discipline
  must_grep "$AGENT" 'retrieval date' "Agent requires retrieval dates on citations"

  # Cache write step
  must_grep "$AGENT" 'cache' "Agent writes cache entries for fetched libraries"

  # Stakes-driven depth
  must_grep "$AGENT" 'Stakes-driven depth' "Agent has stakes-driven depth section"

  # Source-type routing — NOT Context7-as-default.
  # The agent must describe authority hierarchy / question→source routing,
  # not pick a single MCP reflexively. Context7 may appear as ONE example
  # but should not be presented as THE preferred docs MCP for every task.
  if grep -qiE 'authority (order|hierarchy)|authority hierarchy' "$AGENT"; then
    ok "Agent describes question-to-source authority hierarchy (not Context7-first)"
  else
    fail "Authority-hierarchy framing" "agent must describe per-question authority hierarchy, not a fixed tool default"
  fi

  if grep -qiE '(vendor[- ]specific|vendor-owned).*mcp|vendor mcp' "$AGENT"; then
    ok "Agent names vendor-specific MCPs as a source class"
  else
    fail "Vendor MCP framing" "agent must acknowledge vendor MCPs (Stripe, Cloudflare, etc.) as a distinct authority class"
  fi

  if grep -qiE 'filesystem|lockfile|package\.json' "$AGENT"; then
    ok "Agent uses filesystem/lockfile reads for installed-version ground truth"
  else
    fail "Installed-version source" "agent must distinguish 'what's installed' from 'what's current upstream'"
  fi

  if grep -qiE 'github mcp|advisories|changelog' "$AGENT"; then
    ok "Agent acknowledges GitHub MCP / advisories / changelogs as source class"
  else
    fail "Changelog/advisory source" "agent must acknowledge GitHub MCP / advisories / changelogs as a distinct authority class"
  fi

  # Hard budget cap
  must_grep "$AGENT" 'budget' "Agent has explicit wall-clock / lookup budget"
fi

# ============================================================
# orch-stop.sh must prune the research cache
# ============================================================
printf '\n%s== Stop hook integration ==%s\n' "$DIM" "$RESET"
must_grep "$ROOT/scripts/hooks/orch-stop.sh" 'RESEARCH_CACHE_DIR' "Stop hook tracks research cache dir"
must_grep "$ROOT/scripts/hooks/orch-stop.sh" 'ORCH_RESEARCH_RETENTION_DAYS' "Stop hook honors ORCH_RESEARCH_RETENTION_DAYS env var"

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d brief/agent checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
