#!/usr/bin/env bash
# HOME-scoped installer tests — install.sh --global and --codex.
#
# EVERY invocation in this file sets HOME to a fresh mktemp -d. That is not
# hygiene, it is the assertion: the installer is proved to write only where HOME
# points, so a run with HOME pointing at a temp directory cannot have touched the
# real one. Nothing here reads, hashes or stats a path under the developer's own
# home — a test that inspects the real ~/.claude to prove it is untouched is a
# test that can damage it.
#
# Covers:
#   G1  --global creates ~/.claude/CLAUDE.md when it is absent
#   G2  user text above and below the marked region survives byte for byte
#   G3  a second run changes nothing (idempotent)
#   G4  two START markers are refused and nothing is written
#   G5  the rendered block is at most 2 KiB (Codex spends one 32 KiB budget
#       global-first, so an oversized block starves the project's own AGENTS.md)
#   G6  --global and --codex render byte-identical blocks
#   G7  skills/cadence/references/global-block.md is a byte copy of the template
#   G8  --codex copies the skill, marks it, and refuses to remove an unmarked
#       directory it did not write
#   G9  --codex merges the adapter and the Stop pair into ~/.codex/hooks.json,
#       backs the file up, dedups on a second run, never touches config.toml
#   G10 --check's "layers present" report reads HOME from the environment
#   G11 a marker pair the person wrote is not this installer's region
#   G12 a dotfiles-managed link is written through, not over
#   G13 --codex refuses before it writes (malformed hooks.json, read-only dir)
#   G14 a foreign hook survives, the first .bak is the original, stale paths
#   G15 a hooks.json that parses but is not an object is refused first
#   G16 the deleted per-command hooks are stripped, and the installed Stop
#       command actually runs against a rollout fixture
#
# Bash 3.2 compatible. Exits non-zero on any failure.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
TEMPLATE="$ROOT/templates/cadence-global-block.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
section() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RESET"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$TEMPLATE" ]]; then
  printf 'FAIL: test-install-global — missing %s\n' "$TEMPLATE"
  exit 1
fi

# The one rule of this file. Every install.sh call goes through here, so no
# invocation can inherit the developer's HOME by accident.
# mktemp, not a counter: new_home runs inside a command substitution, so a
# counter would increment in the subshell and every caller would get the same
# directory — and then every assertion here would be about one shared home.
new_home() { mktemp -d "$TMP/home.XXXXXX"; }
run_install() {  # run_install <home> <args...>  -> exit code, output in $OUT
  local h="$1"; shift
  OUT=$(env HOME="$h" bash "$INSTALL" "$@" 2>&1)
  return $?
}

START='<!-- ORCH:LAWS:START -->'
END='<!-- ORCH:LAWS:END -->'

# ------------------------------------------------------------
section "G1/G5 — --global into an absent file"
# ------------------------------------------------------------
H1=$(new_home)
if run_install "$H1" --global; then
  if [[ -f "$H1/.claude/CLAUDE.md" ]]; then
    ok "--global creates the global file when it is absent"
  else
    fail "--global creates the global file when it is absent" "no $H1/.claude/CLAUDE.md"
  fi
else
  fail "--global exits 0 on a fresh home" "exit $? — $OUT"
fi

if grep -qF "$START" "$H1/.claude/CLAUDE.md" 2>/dev/null \
   && grep -qF "$END" "$H1/.claude/CLAUDE.md" 2>/dev/null; then
  ok "the rendered file carries both markers"
else
  fail "the rendered file carries both markers" "$(head -3 "$H1/.claude/CLAUDE.md" 2>/dev/null)"
fi

BLOCK_BYTES=$(wc -c < "$TEMPLATE" | tr -d ' ')
if [[ "$BLOCK_BYTES" -le 2048 ]]; then
  ok "the block is ${BLOCK_BYTES} bytes (cap 2048)"
else
  fail "the block is at most 2048 bytes" "it is ${BLOCK_BYTES}"
fi

if printf '%s' "$OUT" | grep -q "rendered .*CLAUDE.md"; then
  ok "--global prints what it rendered"
else
  fail "--global prints what it rendered" "$OUT"
fi

# The HOME proof: everything the run created lives under the temp home.
if [[ -d "$H1/.claude" ]] && [[ "$(cd "$H1" && ls -A)" == ".claude" ]]; then
  ok "the run wrote only under the HOME it was given"
else
  fail "the run wrote only under the HOME it was given" "$(cd "$H1" && ls -A | tr '\n' ' ')"
fi

# ------------------------------------------------------------
section "G2/G3 — user text preserved, second run idempotent"
# ------------------------------------------------------------
H2=$(new_home)
mkdir -p "$H2/.claude"
cat > "$H2/.claude/CLAUDE.md" <<'USERFILE'
# My own notes

Always use tabs. Never ask about tabs again.

## Section the user cares about

- one
- two
USERFILE
cp "$H2/.claude/CLAUDE.md" "$TMP/user-before.md"

run_install "$H2" --global >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then fail "--global on a file without markers" "exit $rc — $OUT"; fi

# Everything before the START marker must be the original file, byte for byte.
awk -v s="$START" 'index($0,s){exit} {print}' "$H2/.claude/CLAUDE.md" > "$TMP/user-after.md"
# The append adds exactly one blank separator line, which is not part of the
# user's text; compare with that trailing blank removed.
awk 'BEGIN{n=0} {a[n++]=$0} END{while(n>0 && a[n-1]==""){n--} for(i=0;i<n;i++) print a[i]}' \
  "$TMP/user-after.md" > "$TMP/user-after-trim.md"
awk 'BEGIN{n=0} {a[n++]=$0} END{while(n>0 && a[n-1]==""){n--} for(i=0;i<n;i++) print a[i]}' \
  "$TMP/user-before.md" > "$TMP/user-before-trim.md"
if cmp -s "$TMP/user-before-trim.md" "$TMP/user-after-trim.md"; then
  ok "the user's text above the region survives byte for byte"
else
  fail "the user's text above the region survives byte for byte" "$(diff "$TMP/user-before-trim.md" "$TMP/user-after-trim.md" | head -5 | tr '\n' ' ')"
fi

cp "$H2/.claude/CLAUDE.md" "$TMP/after-first.md"
run_install "$H2" --global >/dev/null 2>&1
if cmp -s "$TMP/after-first.md" "$H2/.claude/CLAUDE.md"; then
  ok "a second --global changes nothing"
else
  fail "a second --global changes nothing" "$(diff "$TMP/after-first.md" "$H2/.claude/CLAUDE.md" | head -5 | tr '\n' ' ')"
fi

# Text BELOW the region too: replace-in-place must not eat the tail.
H3=$(new_home)
mkdir -p "$H3/.claude"
{ printf 'ABOVE-KEEP\n\n'; cat "$TEMPLATE"; printf '\nBELOW-KEEP\n'; } > "$H3/.claude/CLAUDE.md"
run_install "$H3" --global >/dev/null 2>&1
if grep -q '^ABOVE-KEEP$' "$H3/.claude/CLAUDE.md" && grep -q '^BELOW-KEEP$' "$H3/.claude/CLAUDE.md"; then
  ok "text on both sides of an existing region survives a re-render"
else
  fail "text on both sides of an existing region survives a re-render" "$(cat "$H3/.claude/CLAUDE.md" | head -3 | tr '\n' ' ')"
fi

# ------------------------------------------------------------
section "G4 — two START markers are refused"
# ------------------------------------------------------------
H4=$(new_home)
mkdir -p "$H4/.claude"
{ cat "$TEMPLATE"; printf '\n'; cat "$TEMPLATE"; } > "$H4/.claude/CLAUDE.md"
cp "$H4/.claude/CLAUDE.md" "$TMP/dup-before.md"
if run_install "$H4" --global; then
  fail "duplicate markers are refused" "exit 0 — it should refuse: $OUT"
else
  ok "duplicate markers are refused"
fi
if cmp -s "$TMP/dup-before.md" "$H4/.claude/CLAUDE.md"; then
  ok "a refused --global changes nothing"
else
  fail "a refused --global changes nothing" "the file was modified"
fi

# ------------------------------------------------------------
section "G6/G7 — one source of truth for the block"
# ------------------------------------------------------------
if [[ -f "$ROOT/skills/cadence/references/global-block.md" ]]; then
  if cmp -s "$TEMPLATE" "$ROOT/skills/cadence/references/global-block.md"; then
    ok "the skill's reference copy is byte-identical to the template"
  else
    fail "the skill's reference copy is byte-identical to the template" \
         "$(diff "$TEMPLATE" "$ROOT/skills/cadence/references/global-block.md" | head -5 | tr '\n' ' ')"
  fi
else
  fail "skills/cadence/references/global-block.md exists" "missing"
fi

# ------------------------------------------------------------
section "G6/G8/G9 — --codex: the block, the skill copy, the hooks merge"
# ------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  H5=$(new_home)
  run_install "$H5" --global >/dev/null 2>&1
  run_install "$H5" --codex >/dev/null 2>&1
  cx_rc=$?
  extract_block() {  # <file> -> the marked region, markers included
    awk -v s="$START" -v e="$END" '
      index($0,s){on=1} on{print} index($0,e){on=0}' "$1"
  }
  if [[ $cx_rc -ne 0 ]]; then
    fail "--codex exits 0 with python3 present" "exit $cx_rc — $OUT"
  fi
  if [[ -f "$H5/.codex/AGENTS.md" ]]; then
    extract_block "$H5/.claude/CLAUDE.md" > "$TMP/blk-claude.md"
    extract_block "$H5/.codex/AGENTS.md"  > "$TMP/blk-codex.md"
    if cmp -s "$TMP/blk-claude.md" "$TMP/blk-codex.md"; then
      ok "--global and --codex render byte-identical blocks"
    else
      fail "--global and --codex render byte-identical blocks" \
           "$(diff "$TMP/blk-claude.md" "$TMP/blk-codex.md" | head -5 | tr '\n' ' ')"
    fi
  else
    fail "--codex renders the block into the Codex global file" "no $H5/.codex/AGENTS.md"
  fi

  # G8 — the skill copy and its marker.
  if [[ -f "$H5/.agents/skills/cadence/SKILL.md" ]]; then
    ok "--codex copies the skill into the user skills directory"
  else
    fail "--codex copies the skill into the user skills directory" "no SKILL.md"
  fi
  if [[ -f "$H5/.agents/skills/cadence/.orch-installed" ]]; then
    ok "--codex marks the directory it wrote"
  else
    fail "--codex marks the directory it wrote" "no .orch-installed marker"
  fi
  if [[ -f "$H5/.agents/skills/cadence/scripts/orch-cadence-gate.sh" ]]; then
    ok "the skill's scripts ride along"
  else
    fail "the skill's scripts ride along" "no scripts/orch-cadence-gate.sh"
  fi
  if printf '%s' "$OUT" | grep -qi 're-run'; then
    ok "--codex says the copy is a copy and must be re-run after an update"
  else
    fail "--codex says the copy is a copy and must be re-run after an update" "$OUT"
  fi

  # A directory we did not write is never removed.
  H6=$(new_home)
  mkdir -p "$H6/.agents/skills/cadence"
  printf 'someone else\n' > "$H6/.agents/skills/cadence/SKILL.md"
  if run_install "$H6" --codex; then
    fail "--codex refuses an unmarked destination" "exit 0 — it overwrote a directory it did not write"
  else
    ok "--codex refuses to remove a destination it did not write"
  fi
  if grep -q 'someone else' "$H6/.agents/skills/cadence/SKILL.md" 2>/dev/null; then
    ok "the foreign directory is left exactly as it was"
  else
    fail "the foreign directory is left exactly as it was" "it was modified"
  fi

  # G9 — the hooks.json merge: the adapter on Bash and apply_patch, the
  # completion check and the task cleanup on Stop, every path absolute and
  # present on disk.
  if [[ -f "$H5/.codex/hooks.json" ]]; then
    if python3 - "$H5/.codex/hooks.json" <<'PY' 2>"$TMP/hookerr"
import json, shlex, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))["hooks"]
ms = [m.get("matcher") for m in d.get("PreToolUse", [])]
assert "Bash" in ms and "apply_patch" in ms, ms
def ours(event, base):
    return [h for g in d.get(event, []) for h in g.get("hooks", [])
            if isinstance(h.get("command"), str)
            and any(Path(w).name == base for w in shlex.split(h["command"]))]
ad = ours("PreToolUse", "codex-cadence-adapter.sh")
assert len(ad) == 2, ad
gate = ours("Stop", "codex-verify-gate.sh")
clean = ours("Stop", "orch-task-cleanup.sh")
assert len(gate) == 1 and len(clean) == 1, (gate, clean)
for h in ad + gate + clean:
    words = shlex.split(h["command"])
    assert all(Path(w).is_file() for w in words if "/" in w), h
    assert all(w.startswith("/") for w in words if "/" in w), h
assert gate[0].get("timeout", 0) >= 10 and clean[0].get("timeout", 0) >= 10
# Nothing else of ours anywhere: no per-command evidence hooks, nothing on
# PostToolUse, UserPromptSubmit or the subagent events.
for event in ("PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "SubagentStart", "SubagentStop"):
    assert not d.get(event), (event, d.get(event))
PY
    then
      ok "the merge registers the adapter (Bash, apply_patch) and the Stop pair, absolute and present, and nothing else"
    else
      fail "the merge registers the adapter and the Stop pair" "$(cat "$TMP/hookerr")"
    fi

    run_install "$H5" --codex >/dev/null 2>&1
    n_ad=$(grep -c 'codex-cadence-adapter.sh' "$H5/.codex/hooks.json" || true)
    n_gate=$(grep -c 'codex-verify-gate.sh' "$H5/.codex/hooks.json" || true)
    if [[ "$n_ad" == "2" && "$n_gate" == "1" ]]; then
      ok "a second --codex replaces the entries instead of adding beside them"
    else
      fail "a second --codex replaces the entries instead of adding beside them" "adapter=$n_ad gate=$n_gate"
    fi
    if [[ ! -e "$H5/.codex/hooks.json.bak" ]]; then
      ok "a run that changes nothing writes no backup"
    else
      fail "a run that changes nothing writes no backup" "a .bak appeared for an unchanged file"
    fi
  else
    fail "--codex writes the Codex hooks file" "no $H5/.codex/hooks.json"
  fi

  if [[ -e "$H5/.codex/config.toml" ]]; then
    fail "--codex never touches config.toml" "it created one"
  else
    ok "--codex never touches config.toml"
  fi

  # A foreign entry in hooks.json survives the merge.
  H7=$(new_home)
  mkdir -p "$H7/.codex"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/true"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/false"}]}]}}' \
    > "$H7/.codex/hooks.json"
  run_install "$H7" --codex >/dev/null 2>&1
  if grep -q '/bin/true' "$H7/.codex/hooks.json" && grep -q '/bin/false' "$H7/.codex/hooks.json"; then
    ok "somebody else's hook entries survive the merge, on PreToolUse and on Stop"
  else
    fail "somebody else's hook entries survive the merge" "$(cat "$H7/.codex/hooks.json")"
  fi

# ------------------------------------------------------------
section "G13 — --codex refuses before it writes, and says so"
# ------------------------------------------------------------
  H15=$(new_home)
  mkdir -p "$H15/.codex"
  printf 'not json at all {{{\n' > "$H15/.codex/hooks.json"
  if run_install "$H15" --codex; then
    fail "--codex refuses a malformed hooks.json" "exit 0"
  else
    ok "--codex refuses a malformed hooks.json"
  fi
  if [[ ! -e "$H15/.agents/skills/cadence" ]]; then
    ok "nothing was copied before the refusal"
  else
    fail "nothing was copied before the refusal" "the skill copy landed anyway"
  fi
  if [[ ! -e "$H15/.codex/AGENTS.md" ]]; then
    ok "no block was rendered before the refusal"
  else
    fail "no block was rendered before the refusal" "AGENTS.md was written anyway"
  fi
  if printf '%s' "$OUT" | grep -q '^refused:'; then
    ok "the refusal is a refused: line, not a shell error"
  else
    fail "the refusal is a refused: line, not a shell error" "$OUT"
  fi
  if printf '%s' "$OUT" | grep -qi 'layers present'; then
    ok "the layers report prints on the refusal path too"
  else
    fail "the layers report prints on the refusal path too" "$OUT"
  fi

  H16=$(new_home)
  mkdir -p "$H16/.codex"
  chmod 500 "$H16/.codex"
  if run_install "$H16" --codex; then
    fail "--codex refuses a read-only ~/.codex" "exit 0"
  else
    if printf '%s' "$OUT" | grep -q '^refused:'; then
      ok "a read-only ~/.codex gets a refused: line, not a permission error"
    else
      fail "a read-only ~/.codex gets a refused: line" "$OUT"
    fi
  fi
  chmod 700 "$H16/.codex"

  H22=$(new_home)
  mkdir -p "$H22/.codex" "$H22/.agents/skills/cadence"
  printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$H22/.agents/skills/cadence/.orch-installed"
  printf '# a copy from an older release\n' > "$H22/.agents/skills/cadence/SKILL.md"
  ln -s "$H22/nowhere/hooks.json" "$H22/.codex/hooks.json"
  if run_install "$H22" --codex; then
    fail "--codex refuses a dangling hooks.json link" "exit 0"
  else
    ok "--codex refuses a dangling hooks.json link"
  fi
  if grep -q 'older release' "$H22/.agents/skills/cadence/SKILL.md" && [[ ! -e "$H22/.codex/AGENTS.md" ]]; then
    ok "and that refusal comes before the skill copy and the block render"
  else
    fail "the dangling-link refusal comes before any write" "AGENTS.md: $([[ -e "$H22/.codex/AGENTS.md" ]] && echo written || echo absent)"
  fi

  H23=$(new_home)
  mkdir -p "$H23/.codex/hooks.json" "$H23/.agents/skills/cadence"
  printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$H23/.agents/skills/cadence/.orch-installed"
  printf '# a copy from an older release\n' > "$H23/.agents/skills/cadence/SKILL.md"
  if run_install "$H23" --codex; then
    fail "--codex refuses a hooks.json that is a directory" "exit 0"
  else
    ok "--codex refuses a hooks.json that is a directory"
  fi
  if grep -q 'older release' "$H23/.agents/skills/cadence/SKILL.md" && [[ ! -e "$H23/.codex/AGENTS.md" ]] && printf '%s' "$OUT" | grep -q '^refused:'; then
    ok "and that refusal comes before any write, as a refused: line"
  else
    fail "the directory refusal comes before any write" "$OUT"
  fi

  # The block render's own refusals, asked before the skill copy is replaced.
  for shape in duplicate dangling foreign; do
    H24=$(new_home)
    mkdir -p "$H24/.codex" "$H24/.agents/skills/cadence"
    printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$H24/.agents/skills/cadence/.orch-installed"
    printf '# a copy from an older release\n' > "$H24/.agents/skills/cadence/SKILL.md"
    case "$shape" in
      duplicate) { cat "$TEMPLATE"; printf '\n'; cat "$TEMPLATE"; } > "$H24/.codex/AGENTS.md" ;;
      dangling)  ln -s "$H24/nowhere/AGENTS.md" "$H24/.codex/AGENTS.md" ;;
      foreign)   printf '%s\nmy own text between the markers\n%s\n' "$START" "$END" > "$H24/.codex/AGENTS.md" ;;
    esac
    if run_install "$H24" --codex; then
      fail "--codex refuses an AGENTS.md it cannot render ($shape)" "exit 0"
    else
      ok "--codex refuses an AGENTS.md it cannot render ($shape)"
    fi
    if grep -q 'older release' "$H24/.agents/skills/cadence/SKILL.md" && [[ ! -e "$H24/.codex/hooks.json" ]]; then
      ok "and the skill copy and hooks file are untouched ($shape)"
    else
      fail "the render refusal comes before any write ($shape)" "$OUT"
    fi
  done

# ------------------------------------------------------------
section "G14 — the foreign hook, the backup and the skill copy"
# ------------------------------------------------------------
  H17=$(new_home)
  mkdir -p "$H17/.codex"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/Users/me/llm-orchestrator-notes/my-own-hook.sh"}]}]}}' \
    > "$H17/.codex/hooks.json"
  cp "$H17/.codex/hooks.json" "$TMP/hooks.orig"
  run_install "$H17" --codex >/dev/null 2>&1
  run_install "$H17" --codex >/dev/null 2>&1
  if grep -q 'my-own-hook.sh' "$H17/.codex/hooks.json"; then
    ok "a hook whose path merely contains the plugin's name survives two runs"
  else
    fail "a hook whose path merely contains the plugin's name survives two runs" \
         "$(cat "$H17/.codex/hooks.json")"
  fi
  if cmp -s "$TMP/hooks.orig" "$H17/.codex/hooks.json.bak"; then
    ok "the first .bak is still the pre-install original after a second run"
  else
    fail "the first .bak is still the pre-install original after a second run" \
         "$(cat "$H17/.codex/hooks.json.bak" 2>/dev/null)"
  fi
  n_ad=$(grep -c 'codex-cadence-adapter.sh' "$H17/.codex/hooks.json" || true)
  if [[ "$n_ad" == "2" ]]; then
    ok "exactly one adapter registration per matcher after two runs"
  else
    fail "exactly one adapter registration per matcher after two runs" "found $n_ad"
  fi

  H18=$(new_home)
  run_install "$H18" --codex >/dev/null 2>&1
  printf 'my own note\n' > "$H18/.agents/skills/cadence/MY-NOTES.md"
  cp "$H18/.codex/hooks.json" "$TMP/h18-hooks.before"
  if run_install "$H18" --codex; then
    fail "a re-run refuses when the marked copy holds a file this plugin did not ship" "exit 0"
  else
    ok "a re-run refuses when the marked copy holds a file this plugin did not ship"
  fi
  if [[ -f "$H18/.agents/skills/cadence/MY-NOTES.md" ]] && printf '%s' "$OUT" | grep -q 'MY-NOTES.md' \
     && cmp -s "$TMP/h18-hooks.before" "$H18/.codex/hooks.json"; then
    ok "the refusal names the file, keeps it, and writes nothing"
  else
    fail "the refusal names the file, keeps it, and writes nothing" "$OUT"
  fi
  rm "$H18/.agents/skills/cadence/MY-NOTES.md"
  if run_install "$H18" --codex; then
    ok "with the file moved out, the re-run proceeds"
  else
    fail "with the file moved out, the re-run proceeds" "$OUT"
  fi

  # Ownership is the invoked script, never an argument on the line.
  H25=$(new_home)
  mkdir -p "$H25/.codex"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /home/me/audit.sh codex-evidence.py"}]}]}}' \
    > "$H25/.codex/hooks.json"
  run_install "$H25" --codex >/dev/null 2>&1
  if grep -q '/home/me/audit.sh codex-evidence.py' "$H25/.codex/hooks.json"; then
    ok "a person's hook that merely names a retired file as an argument survives"
  else
    fail "a person's hook that merely names a retired file as an argument survives" "$(cat "$H25/.codex/hooks.json")"
  fi

  # An env-prefixed registration of ours is still ours.
  H29=$(new_home)
  mkdir -p "$H29/.codex"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"env python3 /old/scripts/hooks/codex-evidence.py"},{"type":"command","command":"/usr/bin/env bash /old/scripts/hooks/codex-verify-gate.sh"}]}]}}' \
    > "$H29/.codex/hooks.json"
  run_install "$H29" --codex >/dev/null 2>&1
  if ! grep -q '/old/' "$H29/.codex/hooks.json"; then
    ok "env-prefixed registrations of our scripts are recognised and replaced"
  else
    fail "env-prefixed registrations of our scripts are recognised and replaced" "$(grep '/old/' "$H29/.codex/hooks.json")"
  fi

  # A read-only ~/.codex with nothing else: the refusal creates nothing.
  H30=$(new_home)
  mkdir -p "$H30/.codex"; chmod 500 "$H30/.codex"
  if run_install "$H30" --codex; then
    fail "--codex refuses a read-only ~/.codex" "exit 0"
  else
    ok "--codex refuses a read-only ~/.codex"
  fi
  if [[ ! -e "$H30/.agents" ]]; then
    ok "and creates nothing before that refusal"
  else
    fail "the read-only refusal creates nothing" "$(ls -A "$H30")"
  fi
  chmod 700 "$H30/.codex"

  # ~/.agents as a link outside HOME: the skill copy would land outside.
  H31=$(new_home)
  mkdir -p "$H31.agents-outside"
  ln -s "$H31.agents-outside" "$H31/.agents"
  if run_install "$H31" --codex; then
    fail "--codex refuses a ~/.agents linked outside HOME" "exit 0"
  else
    ok "--codex refuses a ~/.agents linked outside HOME"
  fi
  if [[ -z "$(ls -A "$H31.agents-outside")" && ! -e "$H31/.codex/hooks.json" ]]; then
    ok "and writes nothing outside HOME or under it"
  else
    fail "nothing is written outside HOME" "$(ls -R "$H31.agents-outside")"
  fi
  rm -rf "$H31.agents-outside"

  # A directory inside the marked copy this user cannot write: the copy could
  # not be replaced, so nothing is started.
  H37=$(new_home)
  run_install "$H37" --codex >/dev/null 2>&1
  cp "$H37/.codex/hooks.json" "$TMP/h37.before"
  chmod 500 "$H37/.agents/skills/cadence/scripts"
  printf 'x\n' >> "$H37/.codex/AGENTS.md"
  cp "$H37/.codex/AGENTS.md" "$TMP/h37.agents"
  if run_install "$H37" --codex; then
    fail "--codex refuses a marked copy holding a read-only directory" "exit 0"
  else
    ok "--codex refuses a marked copy holding a read-only directory"
  fi
  if cmp -s "$TMP/h37.before" "$H37/.codex/hooks.json" && cmp -s "$TMP/h37.agents" "$H37/.codex/AGENTS.md" && [[ -f "$H37/.agents/skills/cadence/.orch-installed" ]]; then
    ok "and the hooks, the block and the marker are untouched"
  else
    fail "the read-only-directory refusal comes before any write" "$OUT"
  fi
  chmod 700 "$H37/.agents/skills/cadence/scripts"

  # A link inside the marked copy is the person's too.
  H32=$(new_home)
  run_install "$H32" --codex >/dev/null 2>&1
  mkdir -p "$H32/elsewhere"; printf 'notes\n' > "$H32/elsewhere/notes.md"
  ln -s "$H32/elsewhere/notes.md" "$H32/.agents/skills/cadence/MY-NOTES.md"
  if run_install "$H32" --codex; then
    fail "a re-run refuses when the marked copy holds a link this plugin did not ship" "exit 0"
  else
    ok "a re-run refuses when the marked copy holds a link this plugin did not ship"
  fi
  [[ -L "$H32/.agents/skills/cadence/MY-NOTES.md" ]] && ok "and the link is still there" || fail "the link is still there" "deleted"

  # ~/.agents/skills (a level below) linked outside HOME, and read-only.
  H33=$(new_home)
  mkdir -p "$H33/.agents" "$H33.skills-outside"
  ln -s "$H33.skills-outside" "$H33/.agents/skills"
  if run_install "$H33" --codex; then
    fail "--codex refuses ~/.agents/skills linked outside HOME" "exit 0"
  else
    ok "--codex refuses ~/.agents/skills linked outside HOME"
  fi
  [[ -z "$(ls -A "$H33.skills-outside")" && ! -e "$H33/.codex/hooks.json" ]] && ok "and writes nothing" || fail "nothing written (skills link)" "$(ls -R "$H33.skills-outside")"
  rm -rf "$H33.skills-outside"
  H34=$(new_home)
  mkdir -p "$H34/.agents/skills"; chmod 500 "$H34/.agents/skills"
  if run_install "$H34" --codex; then
    fail "--codex refuses a read-only ~/.agents/skills" "exit 0"
  else
    ok "--codex refuses a read-only ~/.agents/skills"
  fi
  [[ ! -e "$H34/.codex/hooks.json" && ! -e "$H34/.codex/AGENTS.md" ]] && ok "before the hooks and the block are written" || fail "read-only skills dir: nothing written" "$(ls -R "$H34/.codex")"
  chmod 700 "$H34/.agents/skills"

  # AGENTS.md linked into a read-only directory inside HOME.
  H35=$(new_home)
  mkdir -p "$H35/.codex" "$H35/ro"; chmod 500 "$H35/ro"
  ln -s "$H35/ro/AGENTS.md" "$H35/.codex/AGENTS.md"
  if run_install "$H35" --codex; then
    fail "--codex refuses an AGENTS.md linked into a read-only directory" "exit 0"
  else
    ok "--codex refuses an AGENTS.md linked into a read-only directory"
  fi
  [[ ! -e "$H35/.codex/hooks.json" ]] && ok "before the hooks are written" || fail "read-only AGENTS target: nothing written" "$(ls "$H35/.codex")"
  chmod 700 "$H35/ro"

  # A planted temp-file link and a dangling backup link are never followed.
  H36=$(new_home)
  mkdir -p "$H36/.codex" "$H36.victim"
  printf 'unique user work\n' > "$H36.victim/data"
  printf '{"hooks":{}}\n' > "$H36/.codex/hooks.json"
  ln -s "$H36.victim/data" "$H36/.codex/hooks.json.orch-merge.tmp"
  ln -s "$H36.victim/backup" "$H36/.codex/hooks.json.bak"
  run_install "$H36" --codex >/dev/null 2>&1
  if [[ "$(cat "$H36.victim/data")" == "unique user work" && ! -e "$H36.victim/backup" && -f "$H36/.codex/hooks.json" && ! -L "$H36/.codex/hooks.json" ]]; then
    ok "a planted temp-file link and a dangling backup link are not followed"
  else
    fail "planted links are not followed" "$(ls -la "$H36/.codex" "$H36.victim")"
  fi
  rm -rf "$H36.victim"

  # A target reached through `..` is judged by where it really is.
  H26=$(new_home)
  mkdir -p "$H26/.codex" "$H26.outside"
  printf '{"hooks":{}}\n' > "$H26.outside/hooks.json"
  ln -s "$H26/../$(basename "$H26").outside/hooks.json" "$H26/.codex/hooks.json"
  cp "$H26.outside/hooks.json" "$TMP/h26.before"
  if run_install "$H26" --codex; then
    fail "--codex refuses a hooks.json linked outside HOME through .." "exit 0"
  else
    ok "--codex refuses a hooks.json linked outside HOME through .."
  fi
  if cmp -s "$TMP/h26.before" "$H26.outside/hooks.json" && [[ ! -e "$H26/.codex/AGENTS.md" ]]; then
    ok "and the outside file and the block are untouched"
  else
    fail "the outside file and the block are untouched" "$(cat "$H26.outside/hooks.json")"
  fi
  rm -rf "$H26.outside"

  # AGENTS.md that is a directory.
  H27=$(new_home)
  mkdir -p "$H27/.codex/AGENTS.md" "$H27/.agents/skills/cadence"
  printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$H27/.agents/skills/cadence/.orch-installed"
  printf '# a copy from an older release\n' > "$H27/.agents/skills/cadence/SKILL.md"
  if run_install "$H27" --codex; then
    fail "--codex refuses an AGENTS.md that is a directory" "exit 0"
  else
    ok "--codex refuses an AGENTS.md that is a directory"
  fi
  if grep -q 'older release' "$H27/.agents/skills/cadence/SKILL.md" && [[ ! -e "$H27/.codex/hooks.json" ]]; then
    ok "and nothing was written before that refusal"
  else
    fail "nothing was written before the AGENTS.md-directory refusal" "$OUT"
  fi

  # A resolved hooks target whose directory cannot be written.
  H28=$(new_home)
  mkdir -p "$H28/.codex" "$H28/readonly" "$H28/.agents/skills/cadence"
  printf '{"hooks":{}}\n' > "$H28/readonly/hooks.json"
  ln -s "$H28/readonly/hooks.json" "$H28/.codex/hooks.json"
  chmod 500 "$H28/readonly"
  printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$H28/.agents/skills/cadence/.orch-installed"
  printf '# a copy from an older release\n' > "$H28/.agents/skills/cadence/SKILL.md"
  if run_install "$H28" --codex; then
    fail "--codex refuses a hooks target whose directory is read-only" "exit 0"
  else
    ok "--codex refuses a hooks target whose directory is read-only"
  fi
  if grep -q 'older release' "$H28/.agents/skills/cadence/SKILL.md" && [[ ! -e "$H28/.codex/AGENTS.md" ]] && printf '%s' "$OUT" | grep -q '^refused:'; then
    ok "as a refused: line, before any write"
  else
    fail "the read-only target refusal comes before any write" "$OUT"
  fi
  chmod 700 "$H28/readonly"

  H19=$(new_home)
  run_install "$H19" --codex >/dev/null 2>&1
  sed_bin() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
  sed_bin 's|"command": "[^"]*codex-cadence-adapter.sh"|"command": "/nowhere/codex-cadence-adapter.sh"|' \
    "$H19/.codex/hooks.json"
  run_install "$H19" --check >/dev/null 2>&1
  if printf '%s' "$OUT" | grep -q 'stale path'; then
    ok "the layers report calls a dead adapter path stale instead of yes"
  else
    fail "the layers report calls a dead adapter path stale instead of yes" \
         "$(printf '%s' "$OUT" | grep -i 'names the adapter')"
  fi
  if printf '%s' "$OUT" | grep 'names the completion check' | grep -q 'yes$'; then
    ok "the layers report sees the completion check registration"
  else
    fail "the layers report sees the completion check registration" \
         "$(printf '%s' "$OUT" | grep -i 'completion check')"
  fi

# ------------------------------------------------------------
section "G15 — a hooks.json that parses but is not an object"
#
# The preflight tested syntax, not the shape the merge requires: a JSON array
# passes `json.tool`, so the skill was copied and AGENTS.md rendered before the
# merge refused. The refusal has to come first, with the merge's own line.
# ------------------------------------------------------------
  H20=$(new_home)
  mkdir -p "$H20/.codex"
  printf '%s\n' '[{"matcher":"Bash"}]' > "$H20/.codex/hooks.json"
  hj_before=$(shasum -a 256 "$H20/.codex/hooks.json" | awk '{print $1}')
  if run_install "$H20" --codex; then
    fail "--codex refuses a hooks.json that is a JSON array" "exit 0"
  else
    ok "--codex refuses a hooks.json that is a JSON array"
  fi
  if [[ ! -e "$H20/.agents/skills/cadence" ]]; then
    ok "nothing was copied before the refusal (the array shape)"
  else
    fail "nothing was copied before the refusal (the array shape)" "the skill copy landed anyway"
  fi
  if [[ ! -e "$H20/.codex/AGENTS.md" ]]; then
    ok "no block was rendered before the refusal (the array shape)"
  else
    fail "no block was rendered before the refusal (the array shape)" "AGENTS.md was written anyway"
  fi
  if [[ "$(shasum -a 256 "$H20/.codex/hooks.json" | awk '{print $1}')" == "$hj_before" ]]; then
    ok "the hooks file is byte-identical after the refusal"
  else
    fail "the hooks file is byte-identical after the refusal" "$(cat "$H20/.codex/hooks.json")"
  fi
  if printf '%s' "$OUT" | grep -q 'is not a JSON object; nothing was changed.'; then
    ok "the refusal is the line the merge prints today"
  else
    fail "the refusal is the line the merge prints today" "$OUT"
  fi

# ------------------------------------------------------------
section "G16 — the old per-command hooks are removed, and the installed check runs"
#
# v0.8/v0.9 registered codex-evidence.py on every event. v0.10 deleted the
# file and left those registrations in place, so every Codex command failed
# with a missing hook. A --codex over such a file must leave none of them and
# keep the person's own hooks beside them.
# ------------------------------------------------------------
  H21=$(new_home)
  mkdir -p "$H21/.codex"
  cat > "$H21/.codex/hooks.json" <<'STALE'
{"hooks":{
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/scripts/hooks/codex-cadence-adapter.sh"}]},
                {"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}],"matcher":"Bash|apply_patch"}],
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "PostToolUse":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}],"matcher":"Bash|apply_patch|write_stdin"},
                 {"matcher":"Bash","hooks":[{"type":"command","command":"/home/me/mine.sh"}]}],
  "SubagentStart":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "SubagentStop":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "Stop":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]},
          {"hooks":[{"type":"command","command":"bash /old/scripts/hooks/orch-task-cleanup.sh","timeout":10}]}]}}
STALE
  run_install "$H21" --codex >/dev/null 2>&1
  if ! grep -q 'codex-evidence.py' "$H21/.codex/hooks.json" && ! grep -q '/old/' "$H21/.codex/hooks.json"; then
    ok "every registration of the deleted evidence hook, and every stale path of ours, is gone"
  else
    fail "the stale evidence registrations are removed" "$(grep -n 'codex-evidence\|/old/' "$H21/.codex/hooks.json")"
  fi
  if grep -q '/home/me/mine.sh' "$H21/.codex/hooks.json"; then
    ok "the person's own PostToolUse hook beside them survives"
  else
    fail "the person's own PostToolUse hook beside them survives" "$(cat "$H21/.codex/hooks.json")"
  fi

  # ---- Refusals judged by a HOME snapshot: every path under HOME, with its
  # type, mode, size, content hash and link target, taken before and after.
  # A refusal is only a refusal when the two are identical.
  SNAP="$TMP/snap.py"
  cat > "$SNAP" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        path = os.path.join(dirpath, name)
        st = os.lstat(path)
        rel = os.path.relpath(path, root)
        mode = oct(stat.S_IMODE(st.st_mode))
        if stat.S_ISLNK(st.st_mode):
            rows.append("%s link %s -> %s" % (rel, mode, os.readlink(path)))
        elif stat.S_ISDIR(st.st_mode):
            rows.append("%s dir %s" % (rel, mode))
        else:
            with open(path, "rb") as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
            rows.append("%s file %s %d %s" % (rel, mode, st.st_size, digest))
print("\n".join(rows))
PY
  snap() { python3 "$SNAP" "$1"; }

  # A directory this user can write but not enter: -w passes, the copy fails,
  # and the hooks and the block were already written. Refuse before any write.
  H40=$(new_home)
  mkdir -p "$H40/.agents/skills"
  chmod 600 "$H40/.agents/skills"
  BEFORE=$(snap "$H40")
  if run_install "$H40" --codex; then
    fail "--codex refuses a skills directory this user cannot enter" "exit 0"
  else
    printf '%s' "$OUT" | grep -q '^refused:' \
      && ok "--codex refuses a skills directory this user cannot enter" \
      || fail "--codex refuses a skills directory this user cannot enter" "$OUT"
  fi
  AFTER=$(snap "$H40")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical: nothing was written" \
    || fail "unenterable skills dir: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
  chmod 700 "$H40/.agents/skills"

  # A marker below the copy's root is not the marker: notes/.orch-installed is
  # the person's file, named and kept.
  H41=$(new_home)
  run_install "$H41" --codex >/dev/null 2>&1
  mkdir -p "$H41/.agents/skills/cadence/notes"
  printf 'unique personal note\n' > "$H41/.agents/skills/cadence/notes/.orch-installed"
  BEFORE=$(snap "$H41")
  if run_install "$H41" --codex; then
    fail "a re-run refuses a marker-named file below the copy's root" "exit 0"
  else
    printf '%s' "$OUT" | grep -q 'notes/.orch-installed' \
      && ok "a re-run refuses a marker-named file below the copy's root, and names it" \
      || fail "a re-run refuses a marker-named file below the copy's root, and names it" "$OUT"
  fi
  AFTER=$(snap "$H41")
  [[ "$BEFORE" == "$AFTER" && "$(cat "$H41/.agents/skills/cadence/notes/.orch-installed")" == "unique personal note" ]] \
    && ok "and the HOME snapshot is identical: the note is still there" \
    || fail "nested marker: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A regular file wearing a shipped directory's name is the person's file.
  H42=$(new_home)
  run_install "$H42" --codex >/dev/null 2>&1
  rm -rf "$H42/.agents/skills/cadence/references"
  printf 'unique personal reference\n' > "$H42/.agents/skills/cadence/references"
  BEFORE=$(snap "$H42")
  if run_install "$H42" --codex; then
    fail "a re-run refuses a file where the shipped skill has a directory" "exit 0"
  else
    printf '%s' "$OUT" | grep -q 'references' \
      && ok "a re-run refuses a file where the shipped skill has a directory, and names it" \
      || fail "a re-run refuses a file where the shipped skill has a directory, and names it" "$OUT"
  fi
  AFTER=$(snap "$H42")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical: the file is still there" \
    || fail "type collision: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A link where a shipped file should be is the person's link: nothing this
  # plugin ships is a link, so it is refused, not replaced.
  H43=$(new_home)
  run_install "$H43" --codex >/dev/null 2>&1
  mkdir -p "$H43.outside"; printf 'my own skill\n' > "$H43.outside/custom-skill"
  rm "$H43/.agents/skills/cadence/SKILL.md"
  ln -s "$H43.outside/custom-skill" "$H43/.agents/skills/cadence/SKILL.md"
  BEFORE=$(snap "$H43")
  if run_install "$H43" --codex; then
    fail "a re-run refuses a link in place of a shipped file" "exit 0"
  else
    printf '%s' "$OUT" | grep -q 'SKILL.md' \
      && ok "a re-run refuses a link in place of a shipped file, and names it" \
      || fail "a re-run refuses a link in place of a shipped file, and names it" "$OUT"
  fi
  AFTER=$(snap "$H43")
  [[ "$BEFORE" == "$AFTER" && -L "$H43/.agents/skills/cadence/SKILL.md" && "$(cat "$H43.outside/custom-skill")" == "my own skill" ]] \
    && ok "and the HOME snapshot is identical: the link and its target are untouched" \
    || fail "shipped-name link: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # Ownership is the script's name AND its home. An env-var prefix does not
  # hide ours; a person's own script sharing the name is not ours.
  H44=$(new_home)
  mkdir -p "$H44/.codex" "$H44/my-hooks"
  printf '#!/bin/sh\necho FOREIGN_HOOK_RAN\n' > "$H44/my-hooks/codex-verify-gate.sh"
  python3 -c 'import json,sys
root, home = sys.argv[1], sys.argv[2]
json.dump({"hooks": {"Stop": [{"hooks": [
  {"type": "command", "command": "env LANG=C bash %s/scripts/hooks/codex-verify-gate.sh" % root},
  {"type": "command", "command": "bash -c %s/scripts/hooks/codex-verify-gate.sh" % root},
  {"type": "command", "command": "bash -c \"%s/my-hooks/wrap %s/scripts/hooks/codex-verify-gate.sh\"" % (home, root)},
  {"type": "command", "command": "bash %s/my-hooks/codex-verify-gate.sh" % home}]}]}}, open(home + "/.codex/hooks.json", "w"), indent=2)' \
    "$ROOT" "$H44"
  BEFORE=$(snap "$H44/my-hooks")
  run_install "$H44" --codex >/dev/null 2>&1
  AFTER=$(snap "$H44/my-hooks")
  [[ "$BEFORE" == "$AFTER" ]] && ok "the person's own hook script is byte-identical after the run" \
    || fail "person's script untouched" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
  grep -q "my-hooks/wrap " "$H44/.codex/hooks.json" \
    && ok "a person's -c wrapper that names our script as an argument survives" \
    || fail "a person's -c wrapper that names our script as an argument survives" "$(cat "$H44/.codex/hooks.json")"
  n_gate=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["hooks"]
print(sum(1 for g in d.get("Stop", []) for h in g.get("hooks", []) if h.get("command","").endswith("scripts/hooks/codex-verify-gate.sh")))' "$H44/.codex/hooks.json")
  [[ "$n_gate" == "1" ]] && ok "env-prefixed and -c registrations of our gate are replaced, not duplicated (one gate after the run)" \
    || fail "env-prefixed gate registration deduplicated" "found $n_gate: $(cat "$H44/.codex/hooks.json")"
  grep -q "$H44/my-hooks/codex-verify-gate.sh" "$H44/.codex/hooks.json" \
    && ok "a person's own script that shares the gate's name survives" \
    || fail "a person's own script that shares the gate's name survives" "$(cat "$H44/.codex/hooks.json")"

  # Two destinations that are one file: AGENTS.md linked to hooks.json.
  H45=$(new_home)
  mkdir -p "$H45/.codex"
  printf '{}\n' > "$H45/.codex/hooks.json"
  ln -s "$H45/.codex/hooks.json" "$H45/.codex/AGENTS.md"
  BEFORE=$(snap "$H45")
  if run_install "$H45" --codex; then
    fail "--codex refuses an AGENTS.md that is the hooks file" "exit 0"
  else
    printf '%s' "$OUT" | grep -q '^refused:.*same file' \
      && ok "--codex refuses an AGENTS.md that is the hooks file" \
      || fail "--codex refuses an AGENTS.md that is the hooks file" "$OUT"
  fi
  AFTER=$(snap "$H45")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "aliased AGENTS.md: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A destination inside the skill copy, which is replaced whole.
  H46=$(new_home)
  run_install "$H46" --codex >/dev/null 2>&1
  rm "$H46/.codex/hooks.json"
  ln -s "$H46/.agents/skills/cadence/SKILL.md" "$H46/.codex/hooks.json"
  printf '{}\n' > "$H46/.agents/skills/cadence/SKILL.md"
  BEFORE=$(snap "$H46")
  if run_install "$H46" --codex; then
    fail "--codex refuses a hooks file inside the skill copy" "exit 0"
  else
    printf '%s' "$OUT" | grep -q '^refused:.*inside' \
      && ok "--codex refuses a hooks file inside the skill copy" \
      || fail "--codex refuses a hooks file inside the skill copy" "$OUT"
  fi
  AFTER=$(snap "$H46")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "hooks inside skill copy: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A directory inside the copy that find can name but not enter: the refusal
  # is still a named line (a failing find must not end the script silently).
  H47=$(new_home)
  run_install "$H47" --codex >/dev/null 2>&1
  chmod 200 "$H47/.agents/skills/cadence/scripts"
  BEFORE=$(snap "$H47")
  if run_install "$H47" --codex; then
    fail "--codex refuses a directory inside the copy that it cannot enter" "exit 0"
  else
    printf '%s' "$OUT" | grep -Eq '^refused:.*cannot (write, enter or read|scan)' \
      && ok "--codex refuses a directory inside the copy that it cannot enter, with a refused: line" \
      || fail "--codex refuses a directory inside the copy that it cannot enter, with a refused: line" "rc=$? out='$OUT'"
  fi
  AFTER=$(snap "$H47")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "unenterable inner dir: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
  chmod 700 "$H47/.agents/skills/cadence/scripts"

  # A directory the scan can enter but not read (0300): find fails on it and
  # rm could not empty it. The refusal must be a named line, before any
  # write, for a directory inside the copy and for the copy's own root.
  for mode_case in inner root; do
    H51=$(new_home)
    run_install "$H51" --codex >/dev/null 2>&1
    printf '{}\n' > "$H51/.codex/hooks.json"   # a pending merge: a write that must not happen
    if [[ "$mode_case" == inner ]]; then chmod 300 "$H51/.agents/skills/cadence/references"
    else chmod 300 "$H51/.agents/skills/cadence"; fi
    BEFORE=$(snap "$H51")
    if run_install "$H51" --codex; then
      fail "--codex refuses a 0300 ($mode_case) directory in the copy" "exit 0"
    else
      printf '%s' "$OUT" | grep -q '^refused:' \
        && ok "--codex refuses a 0300 ($mode_case) directory in the copy with a refused: line" \
        || fail "--codex refuses a 0300 ($mode_case) directory in the copy with a refused: line" "out='$OUT'"
    fi
    AFTER=$(snap "$H51")
    [[ "$BEFORE" == "$AFTER" && -f "$H51/.agents/skills/cadence/.orch-installed" ]] && ok "and the HOME snapshot is identical ($mode_case)" \
      || fail "0300 $mode_case: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
    if [[ "$mode_case" == inner ]]; then chmod 700 "$H51/.agents/skills/cadence/references"
    else chmod 700 "$H51/.agents/skills/cadence"; fi
  done

  # The copy's own directory this user cannot enter: refused for that reason,
  # not for a marker that could not be read.
  H48=$(new_home)
  run_install "$H48" --codex >/dev/null 2>&1
  chmod 600 "$H48/.agents/skills/cadence"
  BEFORE=$(snap "$H48")
  run_install "$H48" --codex
  printf '%s' "$OUT" | grep -q '^refused:.*not a writable directory' \
    && ok "--codex refuses a marked copy it cannot enter as not writable" \
    || fail "--codex refuses a marked copy it cannot enter as not writable" "$OUT"
  AFTER=$(snap "$H48")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "unenterable copy: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
  chmod 700 "$H48/.agents/skills/cadence"

  # An empty directory of the person's inside the copy is theirs too.
  H49=$(new_home)
  run_install "$H49" --codex >/dev/null 2>&1
  mkdir "$H49/.agents/skills/cadence/mine-empty"
  BEFORE=$(snap "$H49")
  if run_install "$H49" --codex; then
    fail "a re-run refuses an empty directory this plugin did not ship" "exit 0"
  else
    printf '%s' "$OUT" | grep -q 'mine-empty' \
      && ok "a re-run refuses an empty directory this plugin did not ship, and names it" \
      || fail "a re-run refuses an empty directory this plugin did not ship, and names it" "$OUT"
  fi
  AFTER=$(snap "$H49")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "empty foreign dir: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A skill directory that is a link is written through, not replaced.
  H50=$(new_home)
  run_install "$H50" --codex >/dev/null 2>&1
  mv "$H50/.agents/skills/cadence" "$H50/real-copy"
  ln -s "$H50/real-copy" "$H50/.agents/skills/cadence"
  printf 'x\n' >> "$H50/real-copy/SKILL.md"
  if run_install "$H50" --codex && [[ -L "$H50/.agents/skills/cadence" ]] \
     && cmp -s "$H50/real-copy/SKILL.md" "$ROOT/skills/cadence/SKILL.md" && [[ -f "$H50/real-copy/.orch-installed" ]]; then
    ok "a linked skill directory keeps its link and the copy behind it is refreshed"
  else
    fail "a linked skill directory keeps its link and the copy behind it is refreshed" "$OUT link=$([[ -L "$H50/.agents/skills/cadence" ]] && echo yes || echo no)"
  fi

  # Something inside the copy that no permission bit shows (an immutable
  # file): the copy is replaced whole anyway, the old one is moved aside
  # first, and what will not delete is named, not half-removed.
  if command -v chflags >/dev/null 2>&1; then
    H52=$(new_home)
    run_install "$H52" --codex >/dev/null 2>&1
    printf '{}\n' > "$H52/.codex/hooks.json"
    chflags uchg "$H52/.agents/skills/cadence/references/global-block.md"
    run_install "$H52" --codex; rc=$?
    ASIDE=$(ls -d "$H52"/.agents/skills/.cadence.orch-old* 2>/dev/null | head -1)
    if [[ $rc -eq 0 && -f "$H52/.agents/skills/cadence/.orch-installed" ]] \
       && cmp -s "$H52/.agents/skills/cadence/SKILL.md" "$ROOT/skills/cadence/SKILL.md" \
       && cmp -s "$H52/.agents/skills/cadence/references/global-block.md" "$ROOT/skills/cadence/references/global-block.md" \
       && grep -q codex-verify-gate "$H52/.codex/hooks.json" \
       && [[ -n "$ASIDE" ]] && printf '%s' "$OUT" | grep -q "left at .*/.agents/skills/.cadence.orch-old"; then
      ok "an immutable file inside the copy: the new copy is whole, the old one is left aside and named"
    else
      fail "an immutable file inside the copy: the new copy is whole, the old one is left aside and named" "rc=$rc aside='$ASIDE' $OUT"
    fi
    chflags nouchg "$H52/.agents/skills/.cadence.orch-old"*/references/global-block.md 2>/dev/null
    rm -rf "$H52"/.agents/skills/.cadence.orch-old* 2>/dev/null
  fi

  # A dangling ~/.codex link (a dotfiles link whose target is gone) with a
  # marked copy in place: refused before the copy is moved anywhere.
  H54=$(new_home)
  run_install "$H54" --codex >/dev/null 2>&1
  rm -rf "$H54/.codex"; ln -s "$H54/nowhere" "$H54/.codex"
  BEFORE=$(snap "$H54")
  if run_install "$H54" --codex; then
    fail "--codex refuses a dangling ~/.codex link" "exit 0"
  else
    printf '%s' "$OUT" | grep -q '^refused:.*resolves to nothing' \
      && ok "--codex refuses a dangling ~/.codex link with a refused: line" \
      || fail "--codex refuses a dangling ~/.codex link with a refused: line" "out='$OUT'"
  fi
  AFTER=$(snap "$H54")
  [[ "$BEFORE" == "$AFTER" && -f "$H54/.agents/skills/cadence/.orch-installed" ]] && ok "and the HOME snapshot is identical: the copy stayed where it was" \
    || fail "dangling .codex: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"

  # A scratch directory this user cannot write: the scan cannot start, and
  # that is a refused: line too.
  H53=$(new_home)
  run_install "$H53" --codex >/dev/null 2>&1
  mkdir "$H53/ro-tmp"; chmod 500 "$H53/ro-tmp"
  BEFORE=$(snap "$H53")
  if TMPDIR="$H53/ro-tmp" run_install "$H53" --codex; then
    fail "--codex refuses when no scratch file can be made" "exit 0"
  else
    printf '%s' "$OUT" | grep -q '^refused:.*TMPDIR' \
      && ok "--codex refuses when no scratch file can be made, with a refused: line" \
      || fail "--codex refuses when no scratch file can be made, with a refused: line" "out='$OUT'"
  fi
  AFTER=$(snap "$H53")
  [[ "$BEFORE" == "$AFTER" ]] && ok "and the HOME snapshot is identical" \
    || fail "read-only TMPDIR: nothing written" "$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))"
  chmod 700 "$H53/ro-tmp"

  # The registered Stop command, run exactly as hooks.json names it, on a
  # rollout fixture: a PASS with no check sends the agent back; a PASS with a
  # passing check is silent; nothing is ever addressed to the person.
  STOP_CMD=$(python3 -c '
import json,shlex,sys
d=json.load(open(sys.argv[1]))["hooks"]
for g in d["Stop"]:
    for h in g["hooks"]:
        if "codex-verify-gate.sh" in h.get("command",""): print(h["command"])' "$H21/.codex/hooks.json")
  ROLL="$TMP/roll.jsonl"
  python3 - "$ROLL" <<'PY'
import json, sys
def ran(turn, code, cmd):
    return {"type": "event_msg", "payload": {"type": "item_completed", "thread_id": "th", "turn_id": turn,
            "item": {"type": "CommandExecution", "id": "exec-1", "command": ["/bin/zsh", "-lc", cmd],
                     "status": "completed" if code == 0 else "failed", "exit_code": code}}}
rows = [{"type": "event_msg", "payload": {"type": "task_started", "turn_id": "t1"}},
        ran("t1", 0, "ls -la"),
        {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "t2"}},
        ran("t2", 0, "bash tests/test-a.sh")]
with open(sys.argv[1], "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
PY
  stop_payload() { # <turn> -> payload on stdout
    printf '{"session_id":"s","turn_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","model":"m","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Changed: x\\n\\nVerification: PASS"}' "$1" "$ROLL" "$TMP"
  }
  stop_payload t1 | env HOME="$H21" bash -c "$STOP_CMD" > "$TMP/g1.out" 2> "$TMP/g1.err"; rc1=$?
  stop_payload t2 | env HOME="$H21" bash -c "$STOP_CMD" > "$TMP/g2.out" 2> "$TMP/g2.err"; rc2=$?
  if [[ $rc1 -eq 0 ]] && grep -q '"decision": "block"' "$TMP/g1.out" && grep -q 'no check ran and passed' "$TMP/g1.out"; then
    ok "the installed Stop command sends the agent back on a PASS with no check"
  else
    fail "the installed Stop command sends the agent back on a PASS with no check" "rc=$rc1 out=$(cat "$TMP/g1.out") err=$(cat "$TMP/g1.err")"
  fi
  if [[ $rc2 -eq 0 && ! -s "$TMP/g2.out" ]]; then
    ok "the installed Stop command is silent on a PASS with a passing check"
  else
    fail "the installed Stop command is silent on a PASS with a passing check" "rc=$rc2 out=$(cat "$TMP/g2.out")"
  fi
  if ! grep -q 'systemMessage' "$TMP/g1.out" "$TMP/g2.out" && [[ ! -s "$TMP/g1.err" && ! -s "$TMP/g2.err" ]]; then
    ok "nothing is addressed to the person: no systemMessage, nothing on stderr"
  else
    fail "nothing is addressed to the person" "$(cat "$TMP/g1.out" "$TMP/g1.err" "$TMP/g2.err")"
  fi
else
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    fail "--codex probes" "python3 required under ORCH_REQUIRE_DEPS=1"
  else
    printf '  skip --codex probes (python3 missing)\n'
  fi
fi

# ------------------------------------------------------------
section "G10 — the layers report reads HOME from the environment"
# ------------------------------------------------------------
H8=$(new_home)
run_install "$H8" --check >/dev/null 2>&1
CHECK_OUT="$OUT"
if printf '%s' "$CHECK_OUT" | grep -qi 'layers present'; then
  ok "--check prints a layers report"
else
  fail "--check prints a layers report" "$(printf '%s' "$CHECK_OUT" | tail -3 | tr '\n' ' ')"
fi
if printf '%s' "$CHECK_OUT" | grep -qi 'check: OK'; then
  ok "--check is OK in the source checkout"
else
  fail "--check is OK in the source checkout" "$(printf '%s' "$CHECK_OUT" | tail -5 | tr '\n' ' ')"
fi

H9=$(new_home)
mkdir -p "$H9/.claude"
cat "$TEMPLATE" > "$H9/.claude/CLAUDE.md"
run_install "$H9" --check >/dev/null 2>&1
WITH="$OUT"
run_install "$H8" --check >/dev/null 2>&1
WITHOUT="$OUT"
w1=$(printf '%s' "$WITH"    | grep -i 'claude/CLAUDE.md' | head -1)
w0=$(printf '%s' "$WITHOUT" | grep -i 'claude/CLAUDE.md' | head -1)
if [[ -n "$w1" && "$w1" != "$w0" ]]; then
  ok "the report tells a home with the block from one without it"
else
  fail "the report tells a home with the block from one without it" "with='$w1' without='$w0'"
fi

# ------------------------------------------------------------
section "G11 — a marker pair the person wrote is not this installer's region"
#
# The markers are documented, so they appear in people's own notes inside code
# fences. Replacing a region the installer cannot prove it wrote deletes their
# text and renders the laws inside a fence, where they read as sample code.
# ------------------------------------------------------------
H10=$(new_home)
mkdir -p "$H10/.claude"
{ printf '# My notes\n\nThe plugin renders a block between these markers:\n\n'
  printf '```markdown\n%s\nMY OWN EXAMPLE LINE\n%s\n```\n\nkeep this too\n' "$START" "$END"; } \
  > "$H10/.claude/CLAUDE.md"
cp "$H10/.claude/CLAUDE.md" "$TMP/fenced.orig"
if run_install "$H10" --global; then
  fail "--global refuses a marker pair it did not write" "exit 0 — it replaced the region"
else
  ok "--global refuses a marker pair it did not write"
fi
if cmp -s "$TMP/fenced.orig" "$H10/.claude/CLAUDE.md"; then
  ok "the person's fenced example is byte-identical after the refusal"
else
  fail "the person's fenced example is byte-identical after the refusal" "the file changed"
fi
if printf '%s' "$OUT" | grep -q 'lines [0-9]*-[0-9]*'; then
  ok "the refusal names the lines it will not touch"
else
  fail "the refusal names the lines it will not touch" "$OUT"
fi
if ls "$H10/.claude/"CLAUDE.md.bak* >/dev/null 2>&1; then
  fail "nothing was written, so no backup was needed" "a .bak appeared"
else
  ok "nothing was written, so no backup was needed"
fi

# A genuine older block IS replaced, and the original is kept beside it.
H11=$(new_home)
mkdir -p "$H11/.claude"
{ printf 'my own line above\n\n'
  printf '%s\n## The cadence\n\nRead `docs/llm-orchestrator/LAWS.md` first. (an older wording)\n%s\n' "$START" "$END"
  printf '\nmy own line below\n'; } > "$H11/.claude/CLAUDE.md"
cp "$H11/.claude/CLAUDE.md" "$TMP/stale.orig"
if run_install "$H11" --global; then
  ok "--global replaces a genuine older block"
else
  fail "--global replaces a genuine older block" "exit 1 — $OUT"
fi
if cmp -s "$TMP/stale.orig" "$H11/.claude/CLAUDE.md.bak"; then
  ok "the backup is the file exactly as it was before the run"
else
  fail "the backup is the file exactly as it was before the run" "no matching .bak"
fi
if printf '%s' "$OUT" | grep -q 'backup'; then
  ok "the report names the backup it wrote"
else
  fail "the report names the backup it wrote" "$OUT"
fi
run_install "$H11" --global >/dev/null 2>&1
n_bak=$(ls -1 "$H11/.claude/" | grep -c '^CLAUDE.md.bak' || true)
if [[ "$n_bak" == "1" ]]; then
  ok "the idempotent re-run leaves exactly one backup"
else
  fail "the idempotent re-run leaves exactly one backup" "found $n_bak"
fi
if printf '%s' "$OUT" | grep -q 'unchanged'; then
  ok "a re-run that changes nothing says so"
else
  fail "a re-run that changes nothing says so" "$OUT"
fi

# ------------------------------------------------------------
section "G12 — a dotfiles-managed link is written THROUGH, not over"
# ------------------------------------------------------------
H12=$(new_home)
mkdir -p "$H12/.claude" "$H12/dotfiles"
printf 'my dotfiles copy\n' > "$H12/dotfiles/CLAUDE.md"
ln -s "$H12/dotfiles/CLAUDE.md" "$H12/.claude/CLAUDE.md"
run_install "$H12" --global >/dev/null 2>&1
if [[ -L "$H12/.claude/CLAUDE.md" ]]; then
  ok "the link survives --global"
else
  fail "the link survives --global" "it is a regular file now"
fi
if grep -qF "$START" "$H12/dotfiles/CLAUDE.md"; then
  ok "the block lands in the file the link points at"
else
  fail "the block lands in the file the link points at" "the dotfiles copy has no block"
fi

H13=$(new_home)
mkdir -p "$H13/.claude"
ln -s "$H13/dotfiles/gone.md" "$H13/.claude/CLAUDE.md"
if run_install "$H13" --global; then
  fail "--global refuses a dangling link" "exit 0"
else
  ok "--global refuses a dangling link"
fi
if [[ -L "$H13/.claude/CLAUDE.md" && ! -e "$H13/.claude/CLAUDE.md" ]]; then
  ok "the dangling link is left exactly as it was"
else
  fail "the dangling link is left exactly as it was" "it was replaced"
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-install-global%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-install-global — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
