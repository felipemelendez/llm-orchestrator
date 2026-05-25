#!/usr/bin/env bash
# Tests the research-gate UserPromptSubmit hook (orch-research-gate.sh) and
# the SubagentStop validator (orch-researcher-validator.sh).
#
# The sniffer is deterministic — we can curate prompts and assert compel/skip.
# The validator is also deterministic — we craft transcripts + briefs and
# assert mismatch detection.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Curated sniffer tests.
# Three outcomes:
#   compel  — hook emits JSON on stdout (hookSpecificOutput)
#   uncertain — hook emits RESEARCH_UNCERTAIN on stderr only, no JSON on stdout
#   skip    — hook emits nothing at all
_gate_stdout() { printf '{"prompt":"%s"}' "$1" | bash "${ROOT}/scripts/hooks/orch-research-gate.sh" 2>/dev/null; }
_gate_stderr() { printf '{"prompt":"%s"}' "$1" | bash "${ROOT}/scripts/hooks/orch-research-gate.sh" 2>&1 >/dev/null; }

expect_sniffer() {
  local prompt="$1" want="$2"
  local stdout_out stderr_out got
  stdout_out=$(_gate_stdout "${prompt}")
  stderr_out=$(_gate_stderr "${prompt}")
  if [[ -n "${stdout_out}" ]]; then
    got="compel"
  elif echo "${stderr_out}" | grep -q 'RESEARCH_UNCERTAIN'; then
    got="uncertain"
  else
    got="skip"
  fi
  if [[ "${got}" == "${want}" ]]; then
    ok "[sniffer ${want}] ${prompt}"
  else
    fail "[sniffer ${want}, got ${got}]" "${prompt}"
  fi
}

# Expect the gate to emit RESEARCH_UNCERTAIN on stderr but NOT compel.
expect_uncertain() {
  local prompt="$1"
  local stdout_out stderr_out
  stdout_out=$(_gate_stdout "${prompt}")
  stderr_out=$(_gate_stderr "${prompt}")
  if [[ -n "${stdout_out}" ]]; then
    fail "[uncertain, got compel] ${prompt}" "hook emitted JSON (false compel)"
  elif echo "${stderr_out}" | grep -q 'RESEARCH_UNCERTAIN'; then
    ok "[uncertain] ${prompt}"
  else
    fail "[uncertain, got skip] ${prompt}" "hook stayed silent, expected RESEARCH_UNCERTAIN"
  fi
}

# Expect the gate to stay completely silent (no stdout, no RESEARCH_UNCERTAIN stderr).
expect_skip() {
  local prompt="$1"
  local stdout_out stderr_out
  stdout_out=$(_gate_stdout "${prompt}")
  stderr_out=$(_gate_stderr "${prompt}")
  if [[ -n "${stdout_out}" ]]; then
    fail "[skip, got compel] ${prompt}" "hook emitted JSON"
  elif echo "${stderr_out}" | grep -q 'RESEARCH_UNCERTAIN'; then
    fail "[skip, got uncertain] ${prompt}" "hook emitted RESEARCH_UNCERTAIN"
  else
    ok "[skip] ${prompt}"
  fi
}

printf '%s== Sniffer curated tests (design-shape) ==%s\n' "$DIM" "$RESET"
# COMPEL cases — design-shape
expect_sniffer "Add OAuth login with Auth0"                            "compel"
expect_sniffer "Migrate the test suite from Mocha to Vitest"           "compel"
expect_sniffer "Set up Next.js 14 middleware"                          "compel"
expect_sniffer "Add a Prisma migration"                                "compel"
expect_sniffer "Wire Stripe Checkout v15"                              "compel"
expect_sniffer "/llm-orchestrator:research auth0"                      "compel"
expect_sniffer "Implement JWT token refresh"                           "compel"
# SKIP cases — not stale-knowledge research
expect_sniffer "What did we cover in the last session?"                "skip"
expect_sniffer "Run the tests"                                         "skip"
expect_sniffer "Fix the typo in README.md"                             "skip"
expect_sniffer "Add a function that flattens an array"                 "skip"
expect_sniffer "How does our auth code work?"                          "skip"
expect_sniffer "Refactor users.ts to be cleaner"                       "skip"
expect_sniffer "What's our package manager?"                            "skip"
expect_sniffer "What's the test command for this project?"             "skip"

printf '\n%s== Version-signal false-positive guard ==%s\n' "$DIM" "$RESET"
# These phrases contain a design verb so the version-signal branch is reached,
# but they are benign ordinals/counts — must NOT compel.
expect_sniffer "Add a function that covers step 2"   "skip"
expect_sniffer "Implement phase 3 of the plan"       "skip"
expect_sniffer "Build the top 5 features"            "skip"
expect_sniffer "Create task 4 in the backlog"        "skip"
# These MUST compel — they carry real version-shaped tokens.
expect_sniffer "Upgrade to v4"                       "compel"
expect_sniffer "Set up Next.js 15 middleware"        "compel"
expect_sniffer "Add dependency pinned at >=1.55"     "compel"
expect_sniffer "Add version 2.0 of the API"          "compel"
expect_sniffer "Migrate to Python 3.12"              "compel"

printf '\n%s== Sniffer curated tests (structural library detection) ==%s\n' "$DIM" "$RESET"
# COMPEL: off-allowlist libraries detected via structural import/pkg-manager patterns.
# Note: bare "import pandas" (no dot) is no longer a compel — use dotted/quoted/pkg forms.
expect_sniffer "Set up import pandas.DataFrame for the pipeline"         "compel"
expect_sniffer "pip install redis and integrate it"                      "compel"
expect_sniffer "terraform apply to set up infra"                         "compel"
expect_sniffer "import z from 'zod' and implement schema"               "compel"
expect_sniffer "cargo add tokio and build async server"                  "compel"
# Additional code-shaped COMPEL cases (design verb present, module-path-shaped token)
expect_sniffer "Add a step that runs pip install redis"                  "compel"
expect_sniffer "Wire up cargo add tokio"                                 "compel"
expect_sniffer "Add import { z } from \"zod\""                          "compel"
# JS require() — parenthesised form (single quotes; double-quote form also
# matches at the regex level but is not testable via the printf helper because
# bare " inside %s produces malformed JSON — single-quote form covers the branch).
expect_sniffer "Add const redis = require('redis') for caching"         "compel"
# SKIP: bare mention without a design verb — preserve SKIP-bias
expect_sniffer "pandas is great for data science"                        "skip"
expect_sniffer "we use redis at work"                                    "skip"

printf '\n%s== Structural regex false-positive guard ==%s\n' "$DIM" "$RESET"
# These must NOT compel — the structural regex must not match ordinary English
# prepositions ("from the"), modal verbs ("use the"), or non-technical nouns.
# IMPORTANT: these tests include a design verb so the structural regex IS evaluated;
# they are the true test that the module-shape requirement actually prevents false fires.
expect_sniffer "Refactor the function from the old module"               "skip"
expect_sniffer "use the API key"                                         "skip"
expect_sniffer "require approval from a manager"                         "skip"
expect_sniffer "import contacts"                                         "skip"
# Design-verb + prose import — must NOT compel (the real false-positive target).
expect_sniffer "Add code to import contacts from a CSV"                  "skip"
expect_sniffer "Build a feature to use the dashboard"                    "skip"
expect_sniffer "Set up a flow to require approval from a manager"        "skip"
expect_sniffer "Set up a workflow to require sign-off from a manager"    "skip"
expect_sniffer "Refactor the helper to read from the cache"              "skip"
# sam by itself (a person's name) must not trigger the IaC tool branch.
expect_sniffer "build a sam raimi style UI"                              "skip"
# Genuine IaC invocations must still compel.
expect_sniffer "sam deploy the function"                                 "compel"
expect_sniffer "aws sam build the stack"                                 "compel"

printf '\n%s== RESEARCH_UNCERTAIN cry-wolf guard ==%s\n' "$DIM" "$RESET"
# These must NOT emit RESEARCH_UNCERTAIN — plain proper nouns in no-signal context.
expect_skip "Set up Monday morning standup"
expect_skip "Build the London office"
# Known-good UNCERTAIN: design verb + unknown proper noun WITH structural hint.
expect_uncertain "set up Frobnicator integration"

printf '\n%s== Sniffer curated tests (question-shape — Fix 1) ==%s\n' "$DIM" "$RESET"
# Installed-version lookups — compel without design verb
expect_sniffer "What version of openssl is installed in this project?" "compel"
expect_sniffer "What version of React is installed?"                   "compel"
expect_sniffer "Which version of Prisma are we on?"                    "compel"
# Security-advisory queries — compel without design verb
expect_sniffer "Is there a known CVE for our React version?"           "compel"
expect_sniffer "Any CVE for openssl 3.0?"                              "compel"
expect_sniffer "Security advisory for log4j"                           "compel"
# Deprecation-status queries — compel without design verb
expect_sniffer "Is jQuery deprecated for new projects?"                "compel"
expect_sniffer "Is mocha still supported?"                             "compel"

# Validator tests.
printf '\n%s== Validator tests ==%s\n' "$DIM" "$RESET"

TMP=/tmp/orch-research-gate-test
rm -rf "$TMP"
mkdir -p "$TMP/briefs" "$TMP/transcripts"

cat > "$TMP/briefs/clean-verified.md" <<'EOF'
# Research brief
Outcome: VERIFIED
## What was verified
- API matches, all good.
EOF

cat > "$TMP/briefs/sneaky-verified.md" <<'EOF'
# Research brief
Outcome: VERIFIED
- ChatCompletion is deprecated since v1.0
EOF

cat > "$TMP/briefs/sneaky-couldnt.md" <<'EOF'
# Research brief
Outcome: COULDN'T_VERIFY
**Before**
prisma.queryRaw
**After**
prisma.queryRawUnsafe
## Recommended revision
Use queryRawUnsafe in v6.
EOF

cat > "$TMP/briefs/incomplete-contradicted.md" <<'EOF'
# Research brief
Outcome: CONTRADICTED
- API contradicted
EOF

validator_case() {
  local label="$1" status="$2" brief="$3" expect="$4" grep_for="${5:-}"
  local transcript="$TMP/transcripts/${label// /-}.jsonl"
  printf '{"role":"assistant","content":"Status: %s\\nBrief: %s"}\n' "$status" "$brief" > "$transcript"
  local output rc got
  output=$(printf '{"subagent_type":"orch-researcher","transcript_path":"%s"}' "$transcript" \
           | bash "${ROOT}/scripts/hooks/orch-researcher-validator.sh" 2>&1)
  rc=$?
  if [[ "$expect" == "silent" ]]; then
    if [[ "$rc" == "0" && -z "$output" ]]; then
      ok "$label (expected silent)"
    else
      fail "$label" "rc=$rc, output=$output"
    fi
  elif [[ "$expect" == "warn" ]]; then
    if [[ "$rc" == "0" && -n "$output" ]]; then
      if [[ -n "$grep_for" ]] && ! echo "$output" | grep -qF "$grep_for"; then
        fail "$label" "warned but missing expected reason substring '$grep_for' in: $output"
      else
        ok "$label (warned, exit 0)"
      fi
    else
      fail "$label" "rc=$rc, output=$output"
    fi
  fi
}

validator_case "VERIFIED + clean brief"                  "VERIFIED"        "$TMP/briefs/clean-verified.md"          "silent"
validator_case "VERIFIED hides deprecation"              "VERIFIED"        "$TMP/briefs/sneaky-verified.md"         "warn" "brief language indicates a deprecation/removal/rename but Status says VERIFIED"
validator_case "COULDN'T_VERIFY using CONTRADICTED form" "COULDN'T_VERIFY" "$TMP/briefs/sneaky-couldnt.md"          "warn" "CONTRADICTED template) but Status says COULDN'T_VERIFY"
validator_case "CONTRADICTED missing revision section"   "CONTRADICTED"    "$TMP/briefs/incomplete-contradicted.md" "warn" "Status says CONTRADICTED but brief lacks a Recommended revision section"

# NOT_APPLICABLE outcome cases (Fix 2)
cat > "$TMP/briefs/na-proper.md" <<'EOF'
# Research brief
Outcome: NOT_APPLICABLE
**Premise**: project depends on React
**Reality**: no package.json in repo; shell+markdown only
EOF
cat > "$TMP/briefs/na-missing-reality.md" <<'EOF'
# Research brief
Outcome: NOT_APPLICABLE
**Premise**: project depends on React
(no reality field)
EOF
cat > "$TMP/briefs/na-missing-premise.md" <<'EOF'
# Research brief
Outcome: NOT_APPLICABLE
**Reality**: no package.json
(no premise structure)
EOF
cat > "$TMP/briefs/na-softpedal.md" <<'EOF'
# Research brief
Outcome: NOT_APPLICABLE
**Premise**: openai uses ChatCompletion
**Reality**: deprecated in v1
**Before**
openai.ChatCompletion.create
**After**
client.chat.completions.create
## Recommended revision
Use new client API.
EOF

validator_case "NOT_APPLICABLE proper Premise+Reality"   "NOT_APPLICABLE"  "$TMP/briefs/na-proper.md"           "silent"
validator_case "NOT_APPLICABLE missing Reality"          "NOT_APPLICABLE"  "$TMP/briefs/na-missing-reality.md"  "warn" "brief lacks required field(s): Reality"
validator_case "NOT_APPLICABLE missing Premise"          "NOT_APPLICABLE"  "$TMP/briefs/na-missing-premise.md"  "warn" "brief lacks required field(s): Premise"
validator_case "NOT_APPLICABLE soft-pedaling CONTRADICTED" "NOT_APPLICABLE" "$TMP/briefs/na-softpedal.md"        "warn" "NOT_APPLICABLE but brief contains the Before/After"

# Different subagent → skip.
T_OTHER="$TMP/transcripts/other.jsonl"
echo '{"role":"assistant","content":"Status: DONE"}' > "$T_OTHER"
out=$(printf '{"subagent_type":"orch-implementer","transcript_path":"%s"}' "$T_OTHER" \
      | bash "${ROOT}/scripts/hooks/orch-researcher-validator.sh" 2>&1)
rc=$?
if [[ "$rc" == "0" && -z "$out" ]]; then
  ok "Different subagent → silent pass"
else
  fail "Different subagent" "rc=$rc out=$out"
fi

# Strict mode blocks (exit 2).
T_STRICT="$TMP/transcripts/strict.jsonl"
printf '{"role":"assistant","content":"Status: VERIFIED\\nBrief: %s"}\n' "$TMP/briefs/sneaky-verified.md" > "$T_STRICT"
out=$(printf '{"subagent_type":"orch-researcher","transcript_path":"%s"}' "$T_STRICT" \
      | ORCH_STRICT_RESEARCH=1 bash "${ROOT}/scripts/hooks/orch-researcher-validator.sh" 2>&1)
rc=$?
if [[ "$rc" == "2" && "$out" == *"block"* ]]; then
  ok "Strict mode (ORCH_STRICT_RESEARCH=1) blocks with exit 2"
else
  fail "Strict mode" "rc=$rc out=$out"
fi

# ============================================================
# Gate prior-injection tests (Fix 1 + Fix 2 read enforcement)
# ============================================================
# When the sniffer compels, the hook should pre-load priors (cache hits,
# brief-index hits, project memory config, declined_mcp) deterministically.
# These tests verify the additionalContext JSON includes the expected
# section markers when corresponding files exist — and OMITS them when
# the files are absent (graceful fail-open, no false positives).

printf '\n%s== Gate prior-injection tests (Fix 1 + Fix 2 reads) ==%s\n' "$DIM" "$RESET"

PRIORS_HOME="$TMP/priors-home"
mkdir -p "$PRIORS_HOME/research/cache" "$PRIORS_HOME/research/briefs-index" "$PRIORS_HOME/memory"

# Compute the same project hash the hook will compute, so we can place files
# in the right per-project subdirectory.
EXPECTED_HASH=$(bash -c "source ${ROOT}/scripts/lib/orch-project.sh; orch_project_hash")
if [[ -z "$EXPECTED_HASH" ]]; then
  fail "Resolve project hash for priors tests" "orch_project_hash returned empty"
else
  ok "Resolved project hash (${EXPECTED_HASH:0:8}…) for priors test setup"
fi

PRIORS_CACHE_DIR="$PRIORS_HOME/research/cache/$EXPECTED_HASH"
PRIORS_INDEX_FILE="$PRIORS_HOME/research/briefs-index/$EXPECTED_HASH.md"
PRIORS_MEMORY_FILE="$PRIORS_HOME/memory/$EXPECTED_HASH.md"
mkdir -p "$PRIORS_CACHE_DIR"

# Helper: invoke gate hook with given prompt under PRIORS_HOME, capture output.
gate_with_priors() {
  local prompt="$1"
  printf '{"prompt":"%s"}' "${prompt}" \
    | ORCH_HOME="$PRIORS_HOME" bash "${ROOT}/scripts/hooks/orch-research-gate.sh" 2>&1
}

# --- Test: no priors → output omits all prior sections (fail-open) ---
output=$(gate_with_priors "Add Stripe webhook handler")
if [[ -n "$output" ]] \
   && ! echo "$output" | grep -q 'Cache priors' \
   && ! echo "$output" | grep -q 'Prior briefs' \
   && ! echo "$output" | grep -q 'Research config' \
   && ! echo "$output" | grep -q 'Declined MCP'; then
  ok "No prior files → gate emits classifier guidance only, no spurious sections"
else
  fail "No-priors fail-open" "output unexpectedly contains a prior section: $output"
fi

# --- Test: fresh cache file → 'Cache priors' section appears ---
echo "# cached stripe docs" > "$PRIORS_CACHE_DIR/stripe.md"
output=$(gate_with_priors "Add Stripe webhook handler")
if echo "$output" | grep -q 'Cache priors'; then
  ok "Cache file present → 'Cache priors' marker injected"
else
  fail "Cache prior marker" "output missing 'Cache priors': $output"
fi

# --- Test: stale cache file → no Cache priors section (TTL filter works) ---
# 60d-old file with default 30d TTL → should NOT appear.
touch -t 202603200000 "$PRIORS_CACHE_DIR/stripe.md"
output=$(gate_with_priors "Add Stripe webhook handler")
if echo "$output" | grep -q 'Cache priors'; then
  fail "Stale cache filtered" "60d-old cache file leaked past TTL filter"
else
  ok "Stale cache filtered by TTL — no Cache priors section emitted"
fi
# Restore freshness for downstream tests.
touch "$PRIORS_CACHE_DIR/stripe.md"

# --- Test: brief-index entry → 'Prior briefs' section appears ---
mkdir -p "$(dirname "$PRIORS_INDEX_FILE")"
echo "stripe|CONTRADICTED|2026-05-24|docs/examples/2026-05-24-stripe-webhook-contradicted-brief.md" > "$PRIORS_INDEX_FILE"
output=$(gate_with_priors "Add Stripe webhook handler")
if echo "$output" | grep -q 'Prior briefs'; then
  ok "Brief-index entry → 'Prior briefs' marker injected"
else
  fail "Brief-index marker" "output missing 'Prior briefs': $output"
fi
# Verify the outcome label is propagated (not just the path).
if echo "$output" | grep -q 'CONTRADICTED'; then
  ok "Brief-index entry → outcome label flows into context"
else
  fail "Brief outcome in context" "output missing CONTRADICTED: $output"
fi

# --- Test: ## Research config section in memory → 'Research config' marker ---
cat > "$PRIORS_MEMORY_FILE" <<'EOF'
# Project memory

## Conventions
- pnpm not npm (2026-05-23)

## Research config
- research_aggressiveness: high (2026-05-23)
- declined_mcp: stripe-mcp for stripe-api (2026-05-23)

## Decisions
- tRPC over GraphQL (2026-05-23)
EOF

output=$(gate_with_priors "Add Stripe webhook handler")
if echo "$output" | grep -q 'Research config'; then
  ok "## Research config section → 'Research config' marker injected"
else
  fail "Research config marker" "output missing 'Research config': $output"
fi
if echo "$output" | grep -q 'research_aggressiveness'; then
  ok "Aggressiveness value propagated into context"
else
  fail "Aggressiveness propagated" "output missing 'research_aggressiveness': $output"
fi
if echo "$output" | grep -q 'Declined MCP'; then
  ok "declined_mcp entries → 'Declined MCP' marker injected"
else
  fail "Declined MCP marker" "output missing 'Declined MCP': $output"
fi

# --- Test: SKIP path still triggers no priors lookup ---
output=$(gate_with_priors "Fix the typo in README.md")
if [[ -z "$output" ]]; then
  ok "Sniffer SKIP → no output (priors lookup not triggered)"
else
  fail "Sniffer SKIP gate" "expected silent, got: $output"
fi

# ============================================================
# Validator write tests (Fix 1 cache validation + Fix 2 index append)
# ============================================================

printf '\n%s== Validator write tests (Fix 1 + Fix 2 writes) ==%s\n' "$DIM" "$RESET"

WRITE_HOME="$TMP/write-home"
mkdir -p "$WRITE_HOME"

# Reuse the existing clean-verified brief for write tests, but ensure it
# has the Libraries field the validator now parses.
cat > "$TMP/briefs/clean-with-libs.md" <<'EOF'
# Research brief
Outcome: VERIFIED
## What was verified
- Stripe API surface confirmed.
EOF

# Helper: invoke validator with a Status block including a Libraries field.
validator_writes_case() {
  local label="$1" status_line="$2" brief_file="$3"
  local transcript="$TMP/transcripts/write-${label// /-}.jsonl"
  printf '{"role":"assistant","content":"%s\\nBrief: %s"}\n' "$status_line" "$brief_file" > "$transcript"
  printf '{"subagent_type":"orch-researcher","transcript_path":"%s"}' "$transcript" \
    | ORCH_HOME="$WRITE_HOME" bash "${ROOT}/scripts/hooks/orch-researcher-validator.sh" 2>&1
}

INDEX_FILE_WRITE="$WRITE_HOME/research/briefs-index/$EXPECTED_HASH.md"

# --- Test: VERIFIED with 'Libraries verified:' → index gets appended ---
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "verified-with-libs" \
  "Status: VERIFIED\\nLibraries verified: stripe, react" \
  "$TMP/briefs/clean-with-libs.md")
if [[ -f "$INDEX_FILE_WRITE" ]] \
   && grep -q '^stripe|VERIFIED|' "$INDEX_FILE_WRITE" \
   && grep -q '^react|VERIFIED|' "$INDEX_FILE_WRITE"; then
  ok "VERIFIED with Libraries → index appended (stripe + react entries)"
else
  fail "VERIFIED index append" "index file content: $(cat "$INDEX_FILE_WRITE" 2>/dev/null)"
fi

# --- Test: CONTRADICTED with 'Libraries:' → index appended ---
rm -f "$INDEX_FILE_WRITE"
# CONTRADICTED brief needs the recommended-revision section to pass the
# fidelity check (otherwise the validator warns and skips the write path).
cat > "$TMP/briefs/contradicted-complete.md" <<'EOF'
# Research brief
Outcome: CONTRADICTED
## Recommended revision
Use the new endpoint.
EOF
output=$(validator_writes_case "contradicted-with-libs" \
  "Status: CONTRADICTED\\nLibraries: stripe" \
  "$TMP/briefs/contradicted-complete.md")
if [[ -f "$INDEX_FILE_WRITE" ]] && grep -q '^stripe|CONTRADICTED|' "$INDEX_FILE_WRITE"; then
  ok "CONTRADICTED with Libraries → index appended"
else
  fail "CONTRADICTED index append" "index file content: $(cat "$INDEX_FILE_WRITE" 2>/dev/null)"
fi

# --- Test: COULDN'T_VERIFY with 'Libraries attempted:' → index appended ---
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "couldnt-with-libs" \
  "Status: COULDN'T_VERIFY\\nLibraries attempted: prisma" \
  "$TMP/briefs/clean-verified.md")
if [[ -f "$INDEX_FILE_WRITE" ]] && grep -q "^prisma|COULDN'T_VERIFY|" "$INDEX_FILE_WRITE"; then
  ok "COULDN'T_VERIFY with Libraries attempted → index appended"
else
  fail "COULDN'T_VERIFY index append" "index file content: $(cat "$INDEX_FILE_WRITE" 2>/dev/null)"
fi

# --- Test: NOT_APPLICABLE → index NOT touched ---
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "not-applicable-no-index" \
  "Status: NOT_APPLICABLE\\nLibraries: react" \
  "$TMP/briefs/na-proper.md")
if [[ ! -f "$INDEX_FILE_WRITE" ]]; then
  ok "NOT_APPLICABLE → index file not created (indexing deferred)"
else
  fail "NOT_APPLICABLE index skip" "index file was created: $(cat "$INDEX_FILE_WRITE")"
fi

# --- Test: Cache-miss warning when Libraries cited but no cache file exists ---
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "verified-no-cache" \
  "Status: VERIFIED\\nLibraries verified: stripe, react" \
  "$TMP/briefs/clean-with-libs.md")
if echo "$output" | grep -q 'no cache file was written'; then
  ok "Missing cache files → stderr warning"
else
  fail "Cache-miss warning" "expected warning, got: $output"
fi

# --- Test: Cache files exist → no cache-miss warning ---
WRITE_CACHE_DIR="$WRITE_HOME/research/cache/$EXPECTED_HASH"
mkdir -p "$WRITE_CACHE_DIR"
touch "$WRITE_CACHE_DIR/stripe.md" "$WRITE_CACHE_DIR/react.md"
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "verified-all-cache" \
  "Status: VERIFIED\\nLibraries verified: stripe, react" \
  "$TMP/briefs/clean-with-libs.md")
if ! echo "$output" | grep -q 'no cache file was written'; then
  ok "Cache files present → no cache-miss warning"
else
  fail "Cache-present silence" "unexpected warning: $output"
fi

# --- Test: End-to-end compounding loop ---
# Validator writes index → gate reads index on next prompt → marker appears.
rm -f "$INDEX_FILE_WRITE"
output=$(validator_writes_case "e2e-write" \
  "Status: CONTRADICTED\\nLibraries: stripe" \
  "$TMP/briefs/contradicted-complete.md")
e2e_output=$(printf '{"prompt":"Add Stripe webhook handler"}' \
             | ORCH_HOME="$WRITE_HOME" bash "${ROOT}/scripts/hooks/orch-research-gate.sh" 2>&1)
if echo "$e2e_output" | grep -q 'Prior briefs' && echo "$e2e_output" | grep -q 'CONTRADICTED'; then
  ok "End-to-end: validator-written index → next gate invocation surfaces prior brief"
else
  fail "End-to-end compounding loop" "e2e output missing Prior briefs or CONTRADICTED: $e2e_output"
fi

# Cache TTL tests.
printf '\n%s== Cache TTL frontmatter tests ==%s\n' "$DIM" "$RESET"

CACHE=$TMP/cache
mkdir -p "$CACHE/research/cache"

# old + no frontmatter → default 30d → prune
cat > "$CACHE/research/cache/no-fm.md" <<'EOF'
# old cache, no fm
EOF
touch -t 202604200000 "$CACHE/research/cache/no-fm.md"

# old + 90-day TTL → don't prune
cat > "$CACHE/research/cache/long.md" <<'EOF'
---
cache_ttl_days: 90
---
# stable lib
EOF
touch -t 202604200000 "$CACHE/research/cache/long.md"

# old + 7-day TTL → prune
cat > "$CACHE/research/cache/short.md" <<'EOF'
---
cache_ttl_days: 7
---
# volatile
EOF
touch -t 202604200000 "$CACHE/research/cache/short.md"

# fresh + no fm → don't prune
cat > "$CACHE/research/cache/fresh.md" <<'EOF'
# fresh
EOF
touch -t "$(date -v-1d +%Y%m%d%H%M 2>/dev/null || date -d '1 day ago' +%Y%m%d%H%M)" "$CACHE/research/cache/fresh.md"

ORCH_HOME="$CACHE" bash "${ROOT}/scripts/hooks/orch-stop.sh"

if [[ -f "$CACHE/research/cache/long.md" ]]; then ok "90-day TTL keeps 35d-old cache"; else fail "90-day TTL" "long.md was pruned"; fi
if [[ -f "$CACHE/research/cache/fresh.md" ]]; then ok "Fresh cache survives"; else fail "fresh cache" "pruned"; fi
if [[ ! -f "$CACHE/research/cache/no-fm.md" ]]; then ok "Default 30d TTL prunes 35d-old cache"; else fail "default TTL" "no-fm.md still present"; fi
if [[ ! -f "$CACHE/research/cache/short.md" ]]; then ok "7-day TTL prunes 35d-old cache"; else fail "7-day TTL" "short.md still present"; fi

rm -rf "$TMP"

# ============================================================
# Uncertain-signal (RESEARCH_UNCERTAIN) tests
# ============================================================
# When a design verb is present AND a capitalized proper-noun token that
# matches neither the allowlist nor the structural regex is found BUT co-occurs
# with a structural hint (quote, dotted form, or package-manager verb), the
# gate must emit a RESEARCH_UNCERTAIN notice.
# Plain no-signal prompts and plain proper-nouns without structural hints must
# remain completely silent.

printf '\n%s== Uncertain-signal (RESEARCH_UNCERTAIN) tests ==%s\n' "$DIM" "$RESET"

# UNCERTAIN: design verb + unknown cap token with structural hint ("integration"
# suffix accepted as hint for tools that look like tech nouns).
expect_uncertain "set up Frobnicator integration"

# NEGATIVE: plain no-signal prompt → silent.
expect_skip "fix the typo in the readme"

printf '\n'
# ============================================================
# Shared-signals drift detection
# ============================================================
# scripts/lib/orch-signals.sh is the single source of truth for what counts
# as a research-relevant signal. Both the sniffer and the classifier source
# it. This test enforces:
#   (1) the file exists and defines every variable listed in its own map
#   (2) the sniffer sources it
#   (3) every signal class named in the file's SIGNAL_CLASSES_MAP has a
#       matching keyword somewhere in skills/research-classifier/SKILL.md
#
# Drift between the shared file and the classifier skill body is structural
# (silent dead branches in the gate). Hence this fails the build.

printf '\n%s== Shared signals drift detection ==%s\n' "$DIM" "$RESET"

SIGNALS_FILE="$ROOT/scripts/lib/orch-signals.sh"
CLASSIFIER_SKILL="$ROOT/skills/research-classifier/SKILL.md"
SNIFFER="$ROOT/scripts/hooks/orch-research-gate.sh"

if [[ ! -f "$SIGNALS_FILE" ]]; then
  fail "Shared signals file exists" "missing $SIGNALS_FILE"
else
  ok "scripts/lib/orch-signals.sh present"
fi

# Sniffer must source the shared signals file.
if grep -q 'orch-signals.sh' "$SNIFFER"; then
  ok "Sniffer sources scripts/lib/orch-signals.sh"
else
  fail "Sniffer sources shared signals" "orch-research-gate.sh doesn't reference orch-signals.sh"
fi

# Classifier test must source the shared signals file.
if grep -q 'orch-signals.sh' "$ROOT/tests/test-research-classifier.sh"; then
  ok "Classifier test sources scripts/lib/orch-signals.sh"
else
  fail "Classifier test sources shared signals" "test-research-classifier.sh doesn't reference orch-signals.sh"
fi

# Read the SIGNAL_CLASSES_MAP from the shared file; for each variable
# verify (a) the variable is defined, (b) the keyword appears in the
# classifier skill body.
if [[ -f "$SIGNALS_FILE" ]]; then
  # Extract the map block — everything inside ORCH_SIGNAL_CLASSES_MAP='\n ... \n'
  MAP_CONTENT=$(awk "/^ORCH_SIGNAL_CLASSES_MAP=/,/^'\$/" "$SIGNALS_FILE" \
                | grep -E '^ORCH_SIG_[A-Z_]+=' || true)
  while IFS='=' read -r var_name keyword; do
    [[ -z "$var_name" ]] && continue
    # (a) variable must be defined in the file
    if ! grep -qE "^${var_name}=" "$SIGNALS_FILE"; then
      fail "Signal variable defined" "${var_name} listed in MAP but not defined"
      continue
    fi
    # (b) keyword must appear in classifier skill body (case-insensitive)
    # Some keywords have slashes/spaces; do a literal grep -F to be safe.
    if grep -qiF "$keyword" "$CLASSIFIER_SKILL"; then
      ok "Class '$keyword' (${var_name}) referenced in classifier skill body"
    else
      fail "Drift: classifier skill missing signal class" "${var_name} → '$keyword' not found in $CLASSIFIER_SKILL"
    fi
  done <<< "$MAP_CONTENT"
fi

# ============================================================
# Summary
# ============================================================
if (( FAIL == 0 )); then
  printf '%sAll %d gate/validator/TTL checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
