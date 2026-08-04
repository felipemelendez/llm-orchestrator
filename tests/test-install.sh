#!/usr/bin/env bash
# Installer + packaging contract tests.
#
# History: install.sh --copy claimed "Hook paths rewritten to absolute" while its
# sed pattern was brace-blind against the ${CLAUDE_PLUGIN_ROOT} that hooks.json
# actually contains — every --copy install shipped a dead enforcement layer, and
# the smoke check guarding it was brace-blind in exactly the same way. These
# tests assert the POSITIVE property (every command path is absolute and exists
# on disk), never the absence of one spelling of the bug. The assertion here is
# written independently of any checker install.sh itself uses, so the two cannot
# share a blind spot.
#
# Covers:
#   P1  --copy rewrites every hooks.json command to an absolute existing path,
#       and fails loudly (instead of claiming success) when it cannot.
#   P2  docs/install.md Option B wires every hook script hooks.json ships.
#   P3  --copy seeds settings.json from templates/settings.json and ships
#       docs/install.md so the settings _hooks_note pointer resolves.
#   P4  --check fails on deleted referenced files and corrupted JSON.
#   P6  both hard-guard escape hatches are documented.
#   P7  templates/settings.json contains no permission rules that cannot fire.
#   P8  validate-workflows signals degraded mode when node is absent.
#   P10 validate-workflows' empty-directory message states its actual scope.
#
# Bash 3.2 compatible. Exits non-zero on any failure.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
section() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RESET"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The one positive property this file exists for: every type:"command" hook in
# the given hooks.json names an absolute script path that exists on disk, with
# no unexpanded variable text of any spelling. Written inline and from scratch —
# NOT shared with install.sh's own verifier — so a blind spot cannot be common.
assert_hooks_absolute() {
  local name="$1" file="$2"
  local out
  out=$(python3 - "$file" <<'PY' 2>&1
import json, os, shlex, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as e:
    print("hooks.json unparseable: %s" % e); sys.exit(1)
bad, n = [], 0
for event, matchers in data.get("hooks", {}).items():
    for m in matchers:
        for h in m.get("hooks", []):
            if h.get("type") != "command":
                continue
            n += 1
            cmd = h.get("command", "")
            if "$" in cmd:
                bad.append("%s: unexpanded variable text in: %s" % (event, cmd))
                continue
            script = [t for t in shlex.split(cmd) if t.endswith(".sh")]
            if not script:
                bad.append("%s: no script path in: %s" % (event, cmd))
                continue
            for t in script:
                if not os.path.isabs(t):
                    bad.append("%s: not absolute: %s" % (event, t))
                elif not os.path.isfile(t):
                    bad.append("%s: does not exist: %s" % (event, t))
if n == 0:
    bad.append("no command hooks found at all")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
  )
  if [[ -z "$out" ]]; then ok "$name"
  else fail "$name" "$out"; fi
}

# ------------------------------------------------------------
# P1 + P3 — --copy install into a temp project
# ------------------------------------------------------------
section "--copy hook-path rewrite (P1, P3)"

mkdir -p "$TMP/proj"
if bash "$ROOT/scripts/install.sh" --copy "$TMP/proj" > "$TMP/copy.out" 2>&1; then
  ok "--copy exits 0 on a clean install"
else
  fail "--copy exits 0 on a clean install" "$(tail -3 "$TMP/copy.out")"
fi

assert_hooks_absolute "every installed hook command is an absolute existing path" \
                      "$TMP/proj/.claude/hooks/hooks.json"

# The installer may only claim the rewrite when it verified it.
if grep -q "rewritten to absolute" "$TMP/copy.out" \
   && grep -q 'CLAUDE_PLUGIN_ROOT' "$TMP/proj/.claude/hooks/hooks.json"; then
  fail "--copy does not claim a rewrite it did not perform" \
       "output claims rewrite while placeholders survive"
else
  ok "--copy does not claim a rewrite it did not perform"
fi

# A relative dest must still yield absolute paths — "absolute" is only true
# when the prefix itself is.
mkdir -p "$TMP/proj-rel"
( cd "$TMP" && bash "$ROOT/scripts/install.sh" --copy proj-rel ) >/dev/null 2>&1
assert_hooks_absolute "--copy with a relative dest still writes absolute paths" \
                      "$TMP/proj-rel/.claude/hooks/hooks.json"

# P3 — settings seeded from the template, not a hand-written stub.
SETTINGS_OUT=$(python3 - "$TMP/proj/.claude/settings.json" <<'PY' 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
missing = []
if d.get("env", {}).get("ORCH_HOOK_PROFILE") != "standard":
    missing.append("env.ORCH_HOOK_PROFILE=standard")
if "permissions" not in d:
    missing.append("permissions block (template not used as seed)")
if missing:
    print("; ".join(missing)); sys.exit(1)
PY
)
if [[ -z "$SETTINGS_OUT" ]]; then
  ok "generated settings.json is seeded from templates/settings.json"
else
  fail "generated settings.json is seeded from templates/settings.json" "$SETTINGS_OUT"
fi

if [[ -f "$TMP/proj/.claude/docs/install.md" ]]; then
  ok "--copy ships docs/install.md (settings notes point at it)"
else
  fail "--copy ships docs/install.md (settings notes point at it)" \
       "expected $TMP/proj/.claude/docs/install.md"
fi

# ------------------------------------------------------------
# P1 fail-closed — a source whose hooks.json cannot be fully resolved
# must make --copy fail, not print success.
# ------------------------------------------------------------
section "--copy fails closed on unresolvable hooks (P1)"

# Work on a full copy of the checkout (never mutate the real tree).
copy_tree() {
  local dst="$1" item
  mkdir -p "$dst"
  for item in "$ROOT"/* "$ROOT"/.claude-plugin "$ROOT"/.github; do
    [[ -e "$item" ]] || continue
    cp -R "$item" "$dst/"
  done
}

copy_tree "$TMP/src-bad"
# Point one hook at a script that does not exist.
python3 - "$TMP/src-bad/hooks/hooks.json" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace("session-start.sh", "does-not-exist.sh", 1)
io.open(p, "w", encoding="utf-8").write(s)
PY
mkdir -p "$TMP/proj-bad"
if bash "$TMP/src-bad/scripts/install.sh" --copy "$TMP/proj-bad" > "$TMP/copy-bad.out" 2>&1; then
  fail "--copy exits non-zero when a hook command cannot resolve" \
       "exit 0 despite does-not-exist.sh in hooks.json"
else
  ok "--copy exits non-zero when a hook command cannot resolve"
fi

# ------------------------------------------------------------
# P4 — --check must fail on deletions and corruption
# ------------------------------------------------------------
section "--check blind spots (P4)"

copy_tree "$TMP/src"
CHECK="$TMP/src/scripts/install.sh"

expect_check_ok() {
  local name="$1"
  if bash "$CHECK" --check > "$TMP/check.out" 2>&1; then ok "$name"
  else fail "$name" "$(grep -v '^$' "$TMP/check.out" | head -3)"; fi
}
expect_check_fail() {
  local name="$1"
  if bash "$CHECK" --check > "$TMP/check.out" 2>&1; then
    fail "$name" "--check reported OK"
  else ok "$name"; fi
}

expect_check_ok "--check passes on a pristine copy"

# Deleting either of the two hook scripts the old hand list had drifted past.
mv "$TMP/src/scripts/hooks/guard-config-protection.sh" "$TMP/keep.a"
expect_check_fail "--check fails when guard-config-protection.sh is deleted"
mv "$TMP/keep.a" "$TMP/src/scripts/hooks/guard-config-protection.sh"

mv "$TMP/src/scripts/hooks/skill-telemetry.sh" "$TMP/keep.a"
expect_check_fail "--check fails when skill-telemetry.sh is deleted"
mv "$TMP/keep.a" "$TMP/src/scripts/hooks/skill-telemetry.sh"

# Corruption: both JSON files must actually be parsed.
cp "$TMP/src/.claude-plugin/plugin.json" "$TMP/keep.a"
printf 'NOT JSON{{{\n' > "$TMP/src/.claude-plugin/plugin.json"
expect_check_fail "--check fails when plugin.json is not JSON"
cp "$TMP/keep.a" "$TMP/src/.claude-plugin/plugin.json"

cp "$TMP/src/hooks/hooks.json" "$TMP/keep.a"
printf '}}}bad\n' > "$TMP/src/hooks/hooks.json"
expect_check_fail "--check fails when hooks.json is not JSON"
cp "$TMP/keep.a" "$TMP/src/hooks/hooks.json"

# hooks.json referencing a script that does not exist.
cp "$TMP/src/hooks/hooks.json" "$TMP/keep.a"
python3 - "$TMP/src/hooks/hooks.json" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace("subagent-stop.sh", "does-not-exist.sh", 1)
io.open(p, "w", encoding="utf-8").write(s)
PY
expect_check_fail "--check fails when hooks.json references a missing script"
cp "$TMP/keep.a" "$TMP/src/hooks/hooks.json"

# Referenced artifacts proven deletable-without-detection before the fix.
mv "$TMP/src/workflows/review-diff.js" "$TMP/keep.a"
expect_check_fail "--check fails when workflows/review-diff.js is deleted"
mv "$TMP/keep.a" "$TMP/src/workflows/review-diff.js"

mv "$TMP/src/templates/settings.json" "$TMP/keep.a"
expect_check_fail "--check fails when templates/settings.json is deleted"
mv "$TMP/keep.a" "$TMP/src/templates/settings.json"

mv "$TMP/src/docs/install.md" "$TMP/keep.a"
expect_check_fail "--check fails when docs/install.md is deleted"
mv "$TMP/keep.a" "$TMP/src/docs/install.md"

mv "$TMP/src/skills/brainstorming/scripts/server.cjs" "$TMP/keep.a"
expect_check_fail "--check fails when brainstorming server.cjs is deleted"
mv "$TMP/keep.a" "$TMP/src/skills/brainstorming/scripts/server.cjs"

mv "$TMP/src/skills/using-orchestrator" "$TMP/keep.d"
expect_check_fail "--check fails when skills/using-orchestrator/ is deleted"
mv "$TMP/keep.d" "$TMP/src/skills/using-orchestrator"

mv "$TMP/src/templates/plan.md" "$TMP/keep.a"
expect_check_fail "--check fails when a referenced template (plan.md) is deleted"
mv "$TMP/keep.a" "$TMP/src/templates/plan.md"

mv "$TMP/src/commands/plan.md" "$TMP/keep.a"
expect_check_fail "--check fails when a documented command (plan.md) is deleted"
mv "$TMP/keep.a" "$TMP/src/commands/plan.md"

mv "$TMP/src/agents/orch-implementer.md" "$TMP/keep.a"
expect_check_fail "--check fails when agents/orch-implementer.md is deleted"
mv "$TMP/keep.a" "$TMP/src/agents/orch-implementer.md"

# ------------------------------------------------------------
# P2 — docs/install.md Option B completeness
# ------------------------------------------------------------
section "docs/install.md hook wiring (P2)"

DOC_MISSING=$(python3 - "$ROOT/hooks/hooks.json" "$ROOT/docs/install.md" <<'PY'
import io, json, re, sys
hooks = json.load(open(sys.argv[1]))
doc = io.open(sys.argv[2], encoding="utf-8").read()
missing = []
events = set()
for event, matchers in hooks.get("hooks", {}).items():
    events.add(event)
    for m in matchers:
        for h in m.get("hooks", []):
            if h.get("type") != "command":
                continue
            for tok in h.get("command", "").split():
                name = tok.rsplit("/", 1)[-1]
                if name.endswith(".sh") and name not in doc:
                    missing.append(name)
for event in sorted(events):
    if not re.search(r'"%s"' % re.escape(event), doc):
        missing.append("event " + event)
# The type:"prompt" termination-contract hook must at least be mentioned.
if '"prompt"' not in doc and "prompt hook" not in doc:
    missing.append('the type:"prompt" SubagentStop hook')
for m in sorted(set(missing)):
    print(m)
PY
)
if [[ -z "$DOC_MISSING" ]]; then
  ok "every shipped hook script + event appears in docs/install.md"
else
  fail "every shipped hook script + event appears in docs/install.md" \
       "missing: $(printf '%s ' $DOC_MISSING)"
fi

# ------------------------------------------------------------
# P6 — escape hatches documented
# ------------------------------------------------------------
section "escape hatches (P6)"

for knob in ORCH_ALLOW_DESTRUCTIVE_GIT ORCH_ALLOW_CONFIG_EDIT; do
  if grep -q "$knob" "$ROOT/docs/install.md"; then
    ok "$knob documented in docs/install.md"
  else
    fail "$knob documented in docs/install.md" "not found"
  fi
  if grep -q "$knob" "$ROOT/templates/settings.json"; then
    ok "$knob declared in templates/settings.json"
  else
    fail "$knob declared in templates/settings.json" "not found"
  fi
done

# ------------------------------------------------------------
# P7 — no permission rules that cannot fire
# ------------------------------------------------------------
section "template permission rules (P7)"

PERM_OUT=$(python3 - "$ROOT/templates/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
perms = d.get("permissions", {})
bad = []
for kind in ("allow", "ask", "deny"):
    for rule in perms.get(kind, []):
        if rule.startswith("Bash(") and "|" in rule:
            bad.append("%s: %s — commands are matched per pipe-split subcommand; a pattern containing a pipe matches nothing" % (kind, rule))
        if "--force:*" in rule:
            bad.append("%s: %s — :* is a trailing wildcard; flags after other args are not matched" % (kind, rule))
        for tool in ("Glob(", "Grep(", "Write("):
            if rule.startswith(tool):
                bad.append("%s: %s — path rules are consulted for Edit/Read only; this one is never checked" % (kind, rule))
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
)
if [[ -z "$PERM_OUT" ]]; then
  ok "templates/settings.json has no rules that cannot fire"
else
  fail "templates/settings.json has no rules that cannot fire" "$PERM_OUT"
fi

# ------------------------------------------------------------
# P8 + P10 — validate-workflows honesty
# ------------------------------------------------------------
section "validate-workflows (P8, P10)"

# P10: only a nested *.js present — the message must state the actual scope
# (top level of workflows/), not "contains no *.js".
mkdir -p "$TMP/vw/tests/lib" "$TMP/vw/workflows/sub"
cp "$ROOT/tests/validate-workflows.sh" "$TMP/vw/tests/"
# The syntax/meta checker lives in tests/lib/ and the validator refuses to run
# without it — correct, but this case is about the top-level-scope message.
cp "$ROOT/tests/lib/check-workflow-script.mjs" "$TMP/vw/tests/lib/"
printf 'export const meta = {};\n' > "$TMP/vw/workflows/sub/x.js"
VW_OUT=$(bash "$TMP/vw/tests/validate-workflows.sh" 2>&1)
VW_RC=$?
if [[ $VW_RC -ne 0 ]] && printf '%s' "$VW_OUT" | grep -q "top level"; then
  ok "empty-top-level message states its scope and fails"
else
  fail "empty-top-level message states its scope and fails" "rc=$VW_RC out=$VW_OUT"
fi

# P8: with node absent the success line must signal degraded mode and must NOT
# read as the full-validation pass line.
SHIM="$TMP/shim-bin"
mkdir -p "$SHIM"
for t in sh grep find sort head sed cat dirname uname; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$SHIM/$t"
done
NODELESS_OUT=$(PATH="$SHIM" "$BASH" "$ROOT/tests/validate-workflows.sh" 2>&1)
NODELESS_RC=$?
if [[ $NODELESS_RC -eq 0 ]] \
   && printf '%s' "$NODELESS_OUT" | grep -q "degraded" \
   && ! printf '%s' "$NODELESS_OUT" | grep -q "workflow script(s) validated"; then
  ok "node-less run signals degraded mode, not a full pass"
else
  fail "node-less run signals degraded mode, not a full pass" \
       "rc=$NODELESS_RC out=$(printf '%s' "$NODELESS_OUT" | tail -1)"
fi

# ------------------------------------------------------------
# P9 — a --copy install must ship every transitive dependency the hooks load,
# and must ENFORCE the same things the source tree does.
#
# The copy loop was `scripts/lib/*.sh`, and both PreToolUse guards source
# scripts/lib/orch-git-classify.py. So every --copy install shipped the guards
# with their semantic classifier missing; they degraded to spelling rules
# without saying so, and `git reset --har HEAD~1` went from BLOCKED in the
# source tree to ALLOWED in an install. Nothing caught it, because both
# existing verifiers assert hooks.json COMMAND paths and a transitive
# dependency is not one — the check shared the blind spot of the code it
# checked, which is the defect class this whole suite exists for.
#
# Two assertions, deliberately independent: file parity (catches a new lib of
# any extension being left behind) and a behavioural probe (catches the guard
# degrading for any reason at all, including one parity cannot see).
# ------------------------------------------------------------
section "--copy ships transitive deps and enforces identically (P9)"

MISSING_LIB=""
for f in "$ROOT/scripts/lib/"*; do
  [[ -f "$f" ]] || continue
  b="$(basename "$f")"
  [[ -f "$TMP/proj/.claude/scripts/lib/$b" ]] || MISSING_LIB="${MISSING_LIB}${b} "
done
if [[ -z "$MISSING_LIB" ]]; then
  ok "every scripts/lib/* file reaches the install"
else
  fail "every scripts/lib/* file reaches the install" "missing: $MISSING_LIB"
fi

# Behavioural probe: a spelling only the classifier resolves. `--har` is an
# unambiguous prefix of `--hard`, so git really does reset with it.
probe_guard() {  # $1 = guard path, $2 = command; echoes the exit code
  local g="$1" cmd="$2" r rc
  r="$(mktemp -d)"
  ( cd "$r" && git init -q >/dev/null 2>&1 )
  ( cd "$r" && printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd" \
      | bash "$g" >/dev/null 2>&1 )
  rc=$?
  rm -rf "$r"
  printf '%s' "$rc"
}
if command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for probe in "guard-destructive-git.sh:git reset --har HEAD~1" \
               "guard-no-verify.sh:git commit -m x --no-verif"; do
    guard="${probe%%:*}"; cmd="${probe#*:}"
    src_rc="$(probe_guard "$ROOT/scripts/hooks/$guard" "$cmd")"
    ins_rc="$(probe_guard "$TMP/proj/.claude/scripts/hooks/$guard" "$cmd")"
    if [[ "$src_rc" == "2" && "$ins_rc" == "2" ]]; then
      ok "$guard blocks '$cmd' from the install, same as from source"
    elif [[ "$src_rc" != "2" ]]; then
      fail "$guard blocks '$cmd' from source" "source exit=$src_rc (expected 2)"
    else
      fail "$guard blocks '$cmd' from the install" \
           "source exit=$src_rc but install exit=$ins_rc — the install degraded silently"
    fi
  done
else
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    fail "guard parity probe" "git/python3 required under ORCH_REQUIRE_DEPS=1"
  else
    printf '  skip guard parity probe (git or python3 missing)\n'
  fi
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-install%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-install — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
