#!/usr/bin/env bash
# LLM Orchestrator smoke test.
#
# Runs every check that can pass without a live Claude Code session:
#   - Structural: install --check, validate-skills
#   - Hooks: SessionStart, UserPromptSubmit, PreToolUse guard, SubagentStop, Stop
#   - Portable lock under concurrent load (no flock dependency)
#   - /remember section classifier on canonical facts
#   - --copy install: every required file lands, settings.json is valid JSON
#   - Memory: SessionStart loads using-orchestrator skill only (user facts in CLAUDE.md)
#
# Bash 3.2 compatible (works on stock macOS).
# Usage:  ./tests/smoke.sh            run everything
#         ./tests/smoke.sh --quiet    only print failures + summary
#         ./tests/smoke.sh --section <name>   run a single section
#
# Exit codes: 0 = all green, 1 = at least one failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0
SECTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --section) SECTION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
FAILED_CHECKS=()

# ANSI for terminals, plain for pipes/CI
if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

ok()   { (( QUIET )) || printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED_CHECKS+=("$1"); }
section() { (( QUIET )) || printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RESET"; }

# `check NAME CMD`: run CMD silently; ok/fail based on exit code
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"
  else fail "$name" "command: $*"; fi
}

# `check_out NAME EXPECTED CMD`: run CMD, ok if stdout contains EXPECTED
check_out() {
  local name="$1" expected="$2"; shift 2
  local out
  out=$("$@" 2>&1) || { fail "$name" "command failed: $*"; return; }
  if printf '%s' "$out" | grep -qF -- "$expected"; then ok "$name"
  else fail "$name" "expected '$expected' in output; got: $(printf '%s' "$out" | head -1)"; fi
}

# Conditional section gate
should_run() { [[ -z "$SECTION" || "$SECTION" == "$1" ]]; }

# Cleanup any leftover tmp from a prior run
cleanup() {
  rm -rf /tmp/orch-smoke-mem /tmp/orch-smoke-proj /tmp/orch-smoke-lock \
         /tmp/orch-smoke-transcript.jsonl /tmp/orch-smoke-transcript.md \
         /tmp/orch-smoke-prune /tmp/orch-smoke-out.json 2>/dev/null || true
}
trap cleanup EXIT
cleanup

# ------------------------------------------------------------
# 1. Structural checks (delegate to existing scripts)
# ------------------------------------------------------------
if should_run structural; then
  section "Structural"
  check_out "install --check passes" "OK" "${ROOT}/scripts/install.sh" --check
  check_out "validate-skills passes" "OK:" "${ROOT}/tests/validate-skills.sh"
  check_out "research-classifier curated examples pass" "All 15 classifier checks passed" \
            "${ROOT}/tests/test-research-classifier.sh"
  check_out "research-brief + orch-researcher contract pass" "All 41 brief/agent checks passed" \
            "${ROOT}/tests/test-research-brief.sh"
  check_out "research-gate sniffer + validator + cache TTL pass" "gate/validator/TTL checks passed" \
            "${ROOT}/tests/test-research-gate.sh"
  check_out "protocol grader fixture tests pass" "All 14 checks passed" \
            bash "${ROOT}/tests/test-protocol-grader.sh"
  check_out "protocol hook e2e tests pass" "All 25 checks passed" \
            bash "${ROOT}/tests/test-protocol-hooks.sh"
  check_out "detect toolchain + cache tests pass" "All 40 detect checks passed" \
            bash "${ROOT}/tests/test-detect.sh"
  check_out "handoff smoke tests pass" "PASS: smoke-handoff" \
            bash "${ROOT}/tests/handoff/smoke-handoff.sh"
  check_out "handoff nudge/floor tests pass" "PASS: test-token-floor" \
            bash "${ROOT}/tests/handoff/test-token-floor.sh"
  check_out "handoff precompact tests pass" "PASS: test-precompact" \
            bash "${ROOT}/tests/handoff/test-precompact.sh"
fi

# ------------------------------------------------------------
# 2. Hook smoke tests
# ------------------------------------------------------------
if should_run hooks; then
  section "Hooks"

  # SessionStart — loads the using-orchestrator skill body only. User-curated
  # project facts now live in CLAUDE.md (native), loaded by Claude Code itself.
  CLAUDE_PLUGIN_ROOT="$ROOT" ORCH_HOME=/tmp/orch-smoke-mem \
    bash "${ROOT}/scripts/hooks/session-start.sh" > /tmp/orch-smoke-out.json 2>&1

  check "SessionStart emits valid JSON" python3 -m json.tool /tmp/orch-smoke-out.json
  check_out "SessionStart loads using-orchestrator skill" "Using LLM Orchestrator" \
            cat /tmp/orch-smoke-out.json

  # UserPromptSubmit — injects protocol reminder
  bash "${ROOT}/scripts/hooks/user-prompt-submit.sh" > /tmp/orch-smoke-out.json 2>&1
  check "UserPromptSubmit emits valid JSON" python3 -m json.tool /tmp/orch-smoke-out.json
  check_out "UserPromptSubmit reminder mentions the six shape headers" "Changed:" \
            cat /tmp/orch-smoke-out.json
  check_out "UserPromptSubmit requires Verify: in Changed:" "REQUIRE" \
            cat /tmp/orch-smoke-out.json
  check_out "UserPromptSubmit routes 'best approach' to Plan:" "Plan" \
            cat /tmp/orch-smoke-out.json

  # PreToolUse guard — blocks --no-verify
  bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --no-verify -m foo\"}}" | bash "'"${ROOT}"'/scripts/hooks/guard-no-verify.sh"' >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 2 ]]; then ok "Guard blocks --no-verify (exit 2)"
  else fail "Guard blocks --no-verify" "expected exit 2, got $rc"; fi

  # Guard allows clean commit
  bash -c 'echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m foo\"}}" | bash "'"${ROOT}"'/scripts/hooks/guard-no-verify.sh"' >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then ok "Guard allows clean commit (exit 0)"
  else fail "Guard allows clean commit" "expected exit 0, got $rc"; fi

  # SubagentStop — markdown transcript with Status block
  cat > /tmp/orch-smoke-transcript.md <<'EOF'
Doing the thing.
Status: DONE
Summary: ok
Verify:
- pnpm test → 1 passed
EOF
  rc=$(echo "{\"transcript_path\":\"/tmp/orch-smoke-transcript.md\"}" | \
       bash "${ROOT}/scripts/hooks/subagent-stop.sh" >/dev/null 2>&1; echo $?)
  if [[ "$rc" == "0" ]]; then ok "SubagentStop accepts markdown Status block"
  else fail "SubagentStop markdown transcript" "exit $rc"; fi

  # SubagentStop — JSONL transcript with escaped \n
  echo '{"role":"assistant","content":"work done.\nStatus: DONE\nSummary: ok"}' \
    > /tmp/orch-smoke-transcript.jsonl
  rc=$(echo "{\"transcript_path\":\"/tmp/orch-smoke-transcript.jsonl\"}" | \
       bash "${ROOT}/scripts/hooks/subagent-stop.sh" >/dev/null 2>&1; echo $?)
  if [[ "$rc" == "0" ]]; then ok "SubagentStop accepts JSONL escaped-newline Status block"
  else fail "SubagentStop JSONL transcript" "exit $rc"; fi

  # SubagentStop — missing Status block warns but does not block
  echo "no status block here" > /tmp/orch-smoke-transcript.md
  out=$(echo "{\"transcript_path\":\"/tmp/orch-smoke-transcript.md\"}" | \
        bash "${ROOT}/scripts/hooks/subagent-stop.sh" 2>&1)
  rc=$?
  if [[ "$rc" == "0" ]] && [[ "$out" == *"without a Status:"* ]]; then
    ok "SubagentStop warns on missing Status block (exit 0)"
  else fail "SubagentStop missing-Status behavior" "exit=$rc out=$out"; fi

  # orch-stop — prunes old trash entries
  mkdir -p /tmp/orch-smoke-prune/memory/.trash
  touch -t 202001010000 /tmp/orch-smoke-prune/memory/.trash/old.md
  ORCH_HOME=/tmp/orch-smoke-prune bash "${ROOT}/scripts/hooks/orch-stop.sh" >/dev/null 2>&1
  if [[ ! -f /tmp/orch-smoke-prune/memory/.trash/old.md ]]; then
    ok "Stop hook prunes trash older than retention"
  else fail "Stop hook trash pruning" "old trash file still present"; fi
fi

# ------------------------------------------------------------
# 3. Portable lock under concurrent load (no flock dependency)
# ------------------------------------------------------------
if should_run lock; then
  section "Portable lock"
  # shellcheck disable=SC1091
  source "${ROOT}/scripts/lib/orch-lock.sh"
  TF=/tmp/orch-smoke-lock.txt
  rm -f "$TF" "$TF.lock" "$TF.lockdir"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( with_lock "$TF" bash -c "echo line-$i >> '$TF'" ) &
  done
  wait
  LINES=$(wc -l < "$TF" 2>/dev/null | tr -d ' ')
  if [[ "$LINES" == "10" ]]; then ok "10 concurrent with_lock writers → 10 lines"
  else fail "Portable lock concurrent" "expected 10 lines, got $LINES"; fi

  # Stress: injection-safe append
  append_line "$TF" '%s injection $(rm -rf /) `evil`'
  if tail -1 "$TF" | grep -qF '%s injection $(rm -rf /) `evil`'; then
    ok "append_line preserves shell-special chars as literal"
  else fail "append_line injection safety" "special chars mangled"; fi

  # append_under_section — the helper used by /remember
  TF2=/tmp/orch-smoke-section.md
  rm -f "$TF2" "$TF2.lock" "$TF2.lockdir"
  printf '## Conventions\n## Notes\n' > "$TF2"
  append_under_section "$TF2" "Conventions" "- pnpm not npm (2026-01-01)"
  if grep -q '^- pnpm not npm' "$TF2" && head -2 "$TF2" | grep -q 'Conventions'; then
    ok "append_under_section inserts under the named section"
  else fail "append_under_section" "did not insert correctly"; fi

  # Concurrent insert under same section
  rm -f "$TF2" "$TF2.lock" "$TF2.lockdir"
  printf '## Conventions\n' > "$TF2"
  for i in 1 2 3 4 5; do
    ( append_under_section "$TF2" "Conventions" "- fact-$i" ) &
  done
  wait
  COUNT=$(grep -c '^- fact-' "$TF2")
  if [[ "$COUNT" == "5" ]]; then ok "5 concurrent append_under_section → 5 entries"
  else fail "append_under_section concurrent" "expected 5, got $COUNT"; fi

  rm -f "$TF" "$TF.lock" "$TF.lockdir" "$TF2" "$TF2.lock" "$TF2.lockdir"
fi

# ------------------------------------------------------------
# 4. /remember section classifier
# ------------------------------------------------------------
if should_run classifier; then
  section "/remember classifier"

  classify() {
    local LOWER
    LOWER=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$LOWER" in
      *use*|*prefer*|*not*|*formatter*|*lint*|*test*|*package*|*config*|*npm*|*pnpm*|*yarn*|*bun*|*cargo*|*pip*|*poetry*|*uv*|*ruff*|*eslint*|*biome*|*vitest*|*jest*|*mocha*|*pytest*)
        printf 'Conventions' ;;
      *decid*|*chose*|*chosen*|*picked*|*went\ with*)
        printf 'Decisions' ;;
      *own*|*team*|*slack*|*pm*|*engineer*|*lead*|*author*|*maintainer*|*responsible*)
        printf 'People' ;;
      *) printf 'Notes' ;;
    esac
  }

  expect() {
    local fact="$1" want="$2"
    local got
    got=$(classify "$fact")
    if [[ "$got" == "$want" ]]; then ok "'$fact' → $want"
    else fail "Classifier" "'$fact' got '$got', expected '$want'"; fi
  }

  expect "pnpm not npm"                  "Conventions"
  expect "use Vitest for tests"          "Conventions"
  expect "prefer Biome over ESLint"      "Conventions"
  expect "we picked tRPC over GraphQL"   "Decisions"
  expect "chose Postgres over Mongo"     "Decisions"
  expect "Sara owns auth"                "People"
  expect "Sara is the auth owner"        "People"
  expect "API team owns billing"         "People"
  expect "main branch is trunk"          "Notes"
fi

# ------------------------------------------------------------
# 5. --copy install end-to-end
# ------------------------------------------------------------
if should_run install; then
  section "--copy install"
  rm -rf /tmp/orch-smoke-proj
  mkdir -p /tmp/orch-smoke-proj
  ( cd /tmp/orch-smoke-proj && git init -q && git -c user.email=ci@local -c user.name=ci commit --allow-empty -q -m initial )

  "${ROOT}/scripts/install.sh" --copy /tmp/orch-smoke-proj >/dev/null 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "install.sh --copy exits 0" "got $rc"
  else ok "install.sh --copy exits 0"; fi

  for f in \
      .claude/scripts/lib/orch-lock.sh \
      .claude/scripts/hooks/session-start.sh \
      .claude/scripts/hooks/orch-stop.sh \
      .claude/scripts/hooks/user-prompt-submit.sh \
      .claude/scripts/hooks/subagent-stop.sh \
      .claude/scripts/hooks/guard-no-verify.sh \
      .claude/scripts/statusline.sh \
      .claude/output-styles/orchestrator.md \
      .claude/concise-agent-protocol.md \
      .claude/settings.json \
      .claude/hooks/hooks.json; do
    if [[ -f /tmp/orch-smoke-proj/$f ]]; then ok "--copy placed $f"
    else fail "--copy missing $f" "expected at /tmp/orch-smoke-proj/$f"; fi
  done

  check "Generated settings.json is valid JSON" \
        python3 -m json.tool /tmp/orch-smoke-proj/.claude/settings.json
  check "hooks.json paths rewritten to absolute" \
        bash -c "! grep -q '\\\$CLAUDE_PLUGIN_ROOT' /tmp/orch-smoke-proj/.claude/hooks/hooks.json"

  # Re-run SessionStart from the copied install
  CLAUDE_PLUGIN_ROOT=/tmp/orch-smoke-proj/.claude ORCH_HOME=/tmp/orch-smoke-proj-mem \
    bash /tmp/orch-smoke-proj/.claude/scripts/hooks/session-start.sh > /tmp/orch-smoke-out.json 2>&1
  check "SessionStart from --copy emits valid JSON" \
        python3 -m json.tool /tmp/orch-smoke-out.json
  rm -rf /tmp/orch-smoke-proj-mem
fi

# ------------------------------------------------------------
# 6. Documentation sanity (no stale references)
# ------------------------------------------------------------
if should_run docs; then
  section "Documentation"
  # No old "OrchestraKit" or "OK_" identifiers should remain in non-test files.
  # Tests intentionally reference these names when explaining the checks.
  STALE=$(grep -rln 'OrchestraKit\|OK_HOOK\|OK_DISABLED\|OK_ALLOW' "$ROOT" 2>/dev/null \
          | grep -v '\.git/' \
          | grep -v '^.*/tests/' || true)
  if [[ -n "$STALE" ]]; then
    fail "No stale OrchestraKit/OK_ identifiers" "found in: $STALE"
  else ok "No stale OrchestraKit/OK_ identifiers (excluding tests/)"; fi

  # README has a Quick Start section (case-insensitive, anywhere in file)
  if grep -qi '^## Quick [Ss]tart' "$ROOT/README.md"; then
    ok "README has Quick Start section"
  else
    fail "README has Quick Start section" "no '## Quick start' heading found"
  fi

  # No phantom .mcp.json (must be .mcp.json.example)
  if [[ -f "$ROOT/.mcp.json" && ! -f "$ROOT/.mcp.json.example" ]]; then
    fail "MCP config is .example, not auto-load .mcp.json" "found bare .mcp.json"
  else ok ".mcp.json is .example only (no auto-launch)"; fi

  # If a --link install is present, the slash commands' LOCK_LIB probe
  # should find orch-lock.sh at ~/.claude/llm-orchestrator/scripts/lib/.
  LINK_TARGET="$HOME/.claude/llm-orchestrator"
  if [[ -L "$LINK_TARGET" || -d "$LINK_TARGET" ]]; then
    if [[ -f "$LINK_TARGET/scripts/lib/orch-lock.sh" ]]; then
      ok "--link install: orch-lock.sh resolvable from ~/.claude/llm-orchestrator/scripts/lib/"
    else
      fail "--link install missing orch-lock.sh" "expected at $LINK_TARGET/scripts/lib/orch-lock.sh — /remember will fail"
    fi
  else
    ok "(no --link install present to check)"
  fi

  # Plugin marketplace registry exists and is valid JSON
  if [[ ! -f "$ROOT/.claude-plugin/marketplace.json" ]]; then
    fail "marketplace.json present" ".claude-plugin/marketplace.json missing; /plugin marketplace add will fail"
  elif ! python3 -m json.tool < "$ROOT/.claude-plugin/marketplace.json" >/dev/null 2>&1; then
    fail "marketplace.json valid JSON" "parse failed"
  elif ! grep -q '"plugins"' "$ROOT/.claude-plugin/marketplace.json"; then
    fail "marketplace.json has 'plugins' array" "missing key"
  else
    ok "marketplace.json present, valid, lists plugins"
  fi

  # plugin.json present, parseable, and matches Claude Code's schema
  if [[ ! -f "$ROOT/.claude-plugin/plugin.json" ]]; then
    fail "plugin.json present" ".claude-plugin/plugin.json missing"
  elif ! python3 -m json.tool < "$ROOT/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    fail "plugin.json valid JSON" "parse failed"
  else
    SCHEMA_OK=$(python3 -c "
import json, sys
d = json.load(open('$ROOT/.claude-plugin/plugin.json'))
if 'author' in d:
    if not isinstance(d['author'], dict):
        print('author_not_object'); sys.exit(1)
    if 'name' not in d['author']:
        print('author_missing_name'); sys.exit(1)
print('ok')
" 2>&1)
    if [[ "$SCHEMA_OK" == "ok" ]]; then
      ok "plugin.json present and matches Claude Code schema"
    else
      fail "plugin.json schema" "$SCHEMA_OK (author must be {\"name\": ...} object)"
    fi
  fi

  # hooks.json must use the nested hooks:[{type, command}] format
  # (Claude Code plugin schema — flat command field doesn't fire)
  HOOK_FMT_OK=$(python3 -c "
import json, sys
d = json.load(open('$ROOT/hooks/hooks.json'))
if 'hooks' not in d:
    print('missing_hooks_key'); sys.exit(1)
for event, matchers in d['hooks'].items():
    if not isinstance(matchers, list):
        print(f'{event}_not_list'); sys.exit(1)
    for m in matchers:
        if 'hooks' not in m or not isinstance(m['hooks'], list):
            print(f'{event}_missing_inner_hooks_array'); sys.exit(1)
        for h in m['hooks']:
            if h.get('type') != 'command' or 'command' not in h:
                print(f'{event}_inner_hook_malformed'); sys.exit(1)
print('ok')
" 2>&1)
  if [[ "$HOOK_FMT_OK" == "ok" ]]; then
    ok "hooks.json uses nested hooks:[{type,command}] schema"
  else
    fail "hooks.json schema" "$HOOK_FMT_OK — plugin hooks need {matcher,hooks:[{type:'command',command:'...'}]}"
  fi

  # Hook output JSON must include hookEventName field
  OUT=$(CLAUDE_PLUGIN_ROOT="$ROOT" ORCH_HOME=/tmp/orch-smoke-fmt bash "$ROOT/scripts/hooks/session-start.sh" 2>/dev/null)
  if printf '%s' "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get('hookSpecificOutput', {}).get('hookEventName') == 'SessionStart' else 1)
" 2>/dev/null; then
    ok "SessionStart output includes hookEventName field"
  else
    fail "SessionStart hookEventName" "missing from output JSON"
  fi

  OUT=$(bash "$ROOT/scripts/hooks/user-prompt-submit.sh" 2>/dev/null)
  if printf '%s' "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get('hookSpecificOutput', {}).get('hookEventName') == 'UserPromptSubmit' else 1)
" 2>/dev/null; then
    ok "UserPromptSubmit output includes hookEventName field"
  else
    fail "UserPromptSubmit hookEventName" "missing from output JSON"
  fi
  rm -rf /tmp/orch-smoke-fmt
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  printf 'Failed:\n'
  for c in "${FAILED_CHECKS[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
