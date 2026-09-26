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
#   P4  --check fails on deleted referenced files and corrupted JSON, the Codex
#       manifest included.
#   P6  both hard-guard escape hatches are documented.
#   P7  templates/settings.json contains no permission rules that cannot fire.
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
  for item in "$ROOT"/* "$ROOT"/.claude-plugin "$ROOT"/.codex-plugin "$ROOT"/.github; do
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
# P11 — a --copy upgrade leaves nothing the plugin no longer ships, and never
# touches what the project put in .claude/ itself.
# ------------------------------------------------------------
section "--copy upgrade removes what the plugin stopped shipping (P11)"
copy_tree "$TMP/src-old"
mkdir -p "$TMP/src-old/skills/old-skill"
printf 'x\n' > "$TMP/src-old/skills/cadence/references/fixer.md"
printf -- '---\nname: old-skill\ndescription: Use when never.\n---\nold\n' > "$TMP/src-old/skills/old-skill/SKILL.md"
printf 'x\n' > "$TMP/src-old/commands/old-command.md"
printf 'x\n' > "$TMP/src-old/scripts/lib/old-lib.py"
printf 'x\n' > "$TMP/src-old/scripts/hooks/old-hook.sh"
upgrade_scene() { # <label> <project> <drop-manifest 0|1>
  local label="$1" proj="$2" f
  mkdir -p "$proj/.claude/skills/my-skill" "$proj/.claude/commands" "$proj/.claude/scripts"
  printf 'mine\n' > "$proj/.claude/skills/my-skill/SKILL.md"
  printf 'mine\n' > "$proj/.claude/commands/mine.md"
  printf 'mine\n' > "$proj/.claude/scripts/mine.sh"
  bash "$TMP/src-old/scripts/install.sh" --copy "$proj" > "$TMP/up-old.out" 2>&1 \
    || fail "$label: old install" "$(tail -3 "$TMP/up-old.out")"
  [[ -f "$proj/.claude/skills/cadence/references/fixer.md" ]] || fail "$label: fixture" "the old install did not place fixer.md"
  [[ "$3" == "1" ]] && rm -f "$proj/.claude/.llm-orchestrator-files"
  bash "$ROOT/scripts/install.sh" --copy "$proj" > "$TMP/up-new.out" 2>&1 \
    || fail "$label: new install" "$(tail -3 "$TMP/up-new.out")"
  if [[ "$3" == "0" ]]; then
    if [[ ! -e "$proj/.claude/skills/cadence/references/fixer.md" ]]; then
      ok "$label: a file removed from a shipped skill is gone"
    else fail "$label: stale skill file" "skills/cadence/references/fixer.md survived the upgrade"; fi
  else
    # With no record the installer cannot prove it put a file there, so it
    # removes nothing and lists what the plugin no longer ships instead.
    if [[ -f "$proj/.claude/skills/cadence/references/fixer.md" ]] \
       && grep -qF 'skills/cadence/references/fixer.md' "$TMP/up-new.out" && grep -qi 'delete' "$TMP/up-new.out"; then
      ok "$label: nothing is removed; the file the plugin no longer ships is listed for the person to delete"
    else fail "$label: no-record listing" "kept=$([[ -f "$proj/.claude/skills/cadence/references/fixer.md" ]] && echo yes || echo no) out=$(tail -5 "$TMP/up-new.out")"; fi
    grep -qF 'skills/my-skill' "$TMP/up-new.out" && fail "$label: listing" "the project's own skill was listed" \
      || ok "$label: the project's own skill is not listed"
  fi
  for f in skills/my-skill/SKILL.md commands/mine.md scripts/mine.sh; do
    [[ -f "$proj/.claude/$f" ]] && ok "$label: the project's own $f is kept" \
      || fail "$label: own file" "$f was removed"
  done
}
upgrade_scene "with the install record" "$TMP/proj-up" 0
for f in skills/old-skill/SKILL.md commands/old-command.md scripts/lib/old-lib.py scripts/hooks/old-hook.sh; do
  [[ ! -e "$TMP/proj-up/.claude/$f" ]] && ok "with the install record: $f, no longer shipped, is gone" \
    || fail "with the install record: stale $f" "it survived the upgrade"
done
[[ ! -d "$TMP/proj-up/.claude/skills/old-skill" ]] && ok "with the install record: the emptied skill folder is gone" \
  || fail "empty skill dir" "skills/old-skill is still there"
upgrade_scene "an install made before the record existed" "$TMP/proj-up-legacy" 1
[[ -f "$TMP/proj-up-legacy/.claude/.llm-orchestrator-files" ]] && ok "the upgrade writes the install record" \
  || fail "install record" "no .claude/.llm-orchestrator-files after --copy"

# ------------------------------------------------------------
# P12 — the cleanup never deletes a file the plugin did not place, and never
# reaches through a link.
# ------------------------------------------------------------
section "--copy cleanup deletes only what it placed, never through a link (P12)"
# Scene 1: the project owns a read-only file at a path the plugin ships. The
# copy cannot place it (agents/ copy errors are tolerated), so it must not be
# recorded as the plugin's; a later upgrade that retires the path leaves it.
if [[ "$(id -u)" != "0" ]]; then
  copy_tree "$TMP/src-ro"
  printf 'plugin version\n' > "$TMP/src-ro/agents/orch-retired.md"
  P="$TMP/proj-ro"; mkdir -p "$P/.claude/agents"
  printf 'the project'"'"'s own\n' > "$P/.claude/agents/orch-retired.md"; chmod 444 "$P/.claude/agents/orch-retired.md"
  bash "$TMP/src-ro/scripts/install.sh" --copy "$P" > "$TMP/ro1.out" 2>&1 || true
  grep -qxF 'agents/orch-retired.md' "$P/.claude/.llm-orchestrator-files" 2>/dev/null \
    && fail "unplaced file recorded" "agents/orch-retired.md is in the record though the copy could not place it" \
    || ok "a file the copy could not place is not recorded"
  bash "$ROOT/scripts/install.sh" --copy "$P" > "$TMP/ro2.out" 2>&1 || true
  if [[ -f "$P/.claude/agents/orch-retired.md" ]] && grep -qF "the project's own" "$P/.claude/agents/orch-retired.md"; then
    ok "retiring that path leaves the project's own file"
  else fail "project file deleted" "agents/orch-retired.md is gone or changed after the upgrade"; fi
  chmod 644 "$P/.claude/agents/orch-retired.md" 2>/dev/null || true
else
  ok "read-only scene skipped: root ignores file modes"
fi
# Scene 2: an installed skill folder later replaced by a link to a shared
# skill. Retiring that skill must not delete the files behind the link.
P="$TMP/proj-link"; mkdir -p "$P"
bash "$TMP/src-old/scripts/install.sh" --copy "$P" > "$TMP/ln1.out" 2>&1 || fail "link scene: old install" "$(tail -3 "$TMP/ln1.out")"
mkdir -p "$TMP/shared/old-skill"
printf 'shared\n' > "$TMP/shared/old-skill/SKILL.md"
rm -rf "$P/.claude/skills/old-skill"; ln -s "$TMP/shared/old-skill" "$P/.claude/skills/old-skill"
bash "$ROOT/scripts/install.sh" --copy "$P" > "$TMP/ln2.out" 2>&1 || fail "link scene: new install" "$(tail -3 "$TMP/ln2.out")"
[[ -f "$TMP/shared/old-skill/SKILL.md" ]] && ok "a retired skill whose folder is now a link: the file behind the link stays" \
  || fail "deleted through a link" "$TMP/shared/old-skill/SKILL.md is gone"
[[ -L "$P/.claude/skills/old-skill" ]] && ok "and the link itself is left alone" || fail "link removed" "skills/old-skill is no longer a link"

# Scene 3: the person edits a file the plugin placed. When the plugin retires
# that path, the edited file holds their own content: it is kept and listed.
P="$TMP/proj-edit"; mkdir -p "$P"
bash "$TMP/src-old/scripts/install.sh" --copy "$P" > "$TMP/ed1.out" 2>&1 || fail "edit scene: old install" "$(tail -3 "$TMP/ed1.out")"
printf 'my own notes\n' > "$P/.claude/commands/old-command.md"
bash "$ROOT/scripts/install.sh" --copy "$P" > "$TMP/ed2.out" 2>&1 || fail "edit scene: new install" "$(tail -3 "$TMP/ed2.out")"
if [[ -f "$P/.claude/commands/old-command.md" ]] && grep -qF 'my own notes' "$P/.claude/commands/old-command.md"; then
  ok "a retired file the person edited is kept"
else fail "edited file deleted" "commands/old-command.md is gone or changed"; fi
grep -qF 'commands/old-command.md' "$TMP/ed2.out" && grep -qF 'did not add' "$TMP/ed2.out" \
  && ok "and it is listed for the person to delete if it is not theirs" || fail "edited file not listed" "$(tail -5 "$TMP/ed2.out")"
[[ ! -e "$P/.claude/scripts/lib/old-lib.py" ]] && ok "an unchanged retired file in the same upgrade is still removed" \
  || fail "unchanged retired file" "scripts/lib/old-lib.py survived"
head -1 "$P/.claude/.llm-orchestrator-files" | grep -qE '^[0-9a-f]{64}  [^ ]' \
  && ok "the record stores a content hash per file" || fail "record format" "$(head -1 "$P/.claude/.llm-orchestrator-files")"

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

# Deleting a hook script the old hand list had drifted past.
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

# The Codex manifest carries its hooks inline; the same two checks cover it.
cp "$TMP/src/.codex-plugin/plugin.json" "$TMP/keep.a"
printf 'NOT JSON{{{\n' > "$TMP/src/.codex-plugin/plugin.json"
expect_check_fail "--check fails when .codex-plugin/plugin.json is not JSON"
python3 - "$TMP/keep.a" "$TMP/src/.codex-plugin/plugin.json" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
io.open(sys.argv[2], "w", encoding="utf-8").write(s.replace("codex-verify-gate.sh", "does-not-exist.sh", 1))
PY
expect_check_fail "--check fails when .codex-plugin/plugin.json references a missing script"
cp "$TMP/keep.a" "$TMP/src/.codex-plugin/plugin.json"

# Referenced artifacts proven deletable-without-detection before the fix.
mv "$TMP/src/scripts/lib/orch-review.py" "$TMP/keep.a"
expect_check_fail "--check fails when scripts/lib/orch-review.py is deleted"
mv "$TMP/keep.a" "$TMP/src/scripts/lib/orch-review.py"

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

# The cadence files and the libraries hooks load. None of them is derived from
# hooks.json — no hook manifest names them — so the manifest is the only
# thing that fails closed when one of them is deleted, which is exactly the
# blind spot this section exists for.
for cadence_entry in commands/cadence-init.md \
                     scripts/hooks/codex-cadence-adapter.sh \
                     scripts/hooks/codex-verify-gate.sh \
                     scripts/lib/codex-completion-check.py \
                     scripts/lib/codex-cadence-read-command.py \
                     scripts/lib/orch-completion-check.py \
                     scripts/lib/orch-subagent-report.py \
                     skills/cadence/scripts/cadence-ruling.sh \
                     templates/cadence-global-block.md \
                     skills/cadence/SKILL.md \
                     skills/cadence/CADENCE.md \
                     skills/cadence/scripts/orch-cadence-gate.sh \
                     skills/cadence/scripts/orch-cadence-check.sh \
                     skills/cadence/scripts/cadence-detect.sh \
                     skills/cadence/scripts/cadence-init.sh \
                     skills/cadence/references/commit-msg \
                     skills/cadence/references/laws.md; do
  if [[ -f "$TMP/src/$cadence_entry" ]]; then
    mv "$TMP/src/$cadence_entry" "$TMP/keep.a"
    expect_check_fail "--check fails when ${cadence_entry} is deleted"
    mv "$TMP/keep.a" "$TMP/src/$cadence_entry"
  else
    fail "--check fails when ${cadence_entry} is deleted" "the file is not in the checkout"
  fi
done

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

for knob in ORCH_ALLOW_DESTRUCTIVE_GIT; do
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
# P10 — the cadence check script reaches a --copy install.
#
# `${CLAUDE_PLUGIN_ROOT}` is rewritten only inside the plugin's hook manifest, so
# anything that resolves the check script through that token is wrong in a --copy
# layout. The commit-msg hook and `--audit` both call the script from wherever the
# install put it, which is one of two places:
#   plugin: <plugin>/skills/cadence/scripts/orch-cadence-check.sh
#   --copy: <proj>/.claude/skills/cadence/scripts/orch-cadence-check.sh
# ------------------------------------------------------------
section "--copy ships the cadence check script (P10)"

if [[ -f "$TMP/proj/.claude/skills/cadence/scripts/orch-cadence-check.sh" ]]; then
  ok "the cadence check script reaches .claude/skills/cadence/scripts/"
else
  fail "the cadence check script reaches .claude/skills/cadence/scripts/" \
       "missing $TMP/proj/.claude/skills/cadence/scripts/orch-cadence-check.sh"
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
