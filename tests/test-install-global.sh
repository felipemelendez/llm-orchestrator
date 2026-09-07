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
#   G9  --codex merges the adapter hook into ~/.codex/hooks.json, backs the file
#       up, dedups on a second run, and never touches ~/.codex/config.toml
#   G10 --check's "layers present" report reads HOME from the environment
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

  # G9 — the hooks.json merge.
  if [[ -f "$H5/.codex/hooks.json" ]]; then
    if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
ms=[m.get("matcher") for m in d.get("hooks",{}).get("PreToolUse",[])]
cmds=[h.get("command","") for m in d.get("hooks",{}).get("PreToolUse",[]) for h in m.get("hooks",[])]
assert "Bash" in ms, ms
assert "apply_patch" in ms, ms
assert all(c.startswith("/") for c in cmds), cmds
assert all("codex-cadence-adapter.sh" in c for c in cmds), cmds
' "$H5/.codex/hooks.json" 2>"$TMP/hookerr"; then
      ok "the hook entry names both matchers with an absolute adapter path"
    else
      fail "the hook entry names both matchers with an absolute adapter path" "$(cat "$TMP/hookerr")"
    fi

    run_install "$H5" --codex >/dev/null 2>&1
    if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
cmds=[h.get("command","") for m in d.get("hooks",{}).get("PreToolUse",[]) for h in m.get("hooks",[])]
ours=[c for c in cmds if "codex-cadence-adapter" in c or "llm-orchestrator" in c]
assert len(ours)==2, ours
' "$H5/.codex/hooks.json" 2>"$TMP/hookerr2"; then
      ok "a second --codex replaces the entry instead of adding a second one"
    else
      fail "a second --codex replaces the entry instead of adding a second one" "$(cat "$TMP/hookerr2")"
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
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/true"}]}]}}' \
    > "$H7/.codex/hooks.json"
  run_install "$H7" --codex >/dev/null 2>&1
  if grep -q '/bin/true' "$H7/.codex/hooks.json"; then
    ok "somebody else's hook entry survives the merge"
  else
    fail "somebody else's hook entry survives the merge" "$(cat "$H7/.codex/hooks.json")"
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

if command -v python3 >/dev/null 2>&1; then
  H14=$(new_home)
  mkdir -p "$H14/.codex" "$H14/dotfiles"
  printf '{"hooks":{}}\n' > "$H14/dotfiles/hooks.json"
  ln -s "$H14/dotfiles/hooks.json" "$H14/.codex/hooks.json"
  run_install "$H14" --codex >/dev/null 2>&1
  if [[ -L "$H14/.codex/hooks.json" ]] && grep -q 'codex-cadence-adapter' "$H14/dotfiles/hooks.json"; then
    ok "--codex merges through a linked hooks.json instead of replacing the link"
  else
    fail "--codex merges through a linked hooks.json" "link=$( [[ -L "$H14/.codex/hooks.json" ]] && echo yes || echo no)"
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
  run_install "$H18" --codex >/dev/null 2>&1
  if printf '%s' "$OUT" | grep -q 'MY-NOTES.md'; then
    ok "a re-run names the person's file before it deletes the skill copy"
  else
    fail "a re-run names the person's file before it deletes the skill copy" "$OUT"
  fi

  H19=$(new_home)
  run_install "$H19" --codex >/dev/null 2>&1
  sed_bin() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }
  sed_bin 's|"command": "[^"]*"|"command": "/nowhere/codex-cadence-adapter.sh"|' \
    "$H19/.codex/hooks.json"
  run_install "$H19" --check >/dev/null 2>&1
  if printf '%s' "$OUT" | grep -q 'stale path'; then
    ok "the layers report calls a dead adapter path stale instead of yes"
  else
    fail "the layers report calls a dead adapter path stale instead of yes" \
         "$(printf '%s' "$OUT" | grep -i 'names the adapter')"
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
  if printf '%s' "$OUT" | grep -qi 'layers present'; then
    ok "the layers report prints on this refusal path too"
  else
    fail "the layers report prints on this refusal path too" "$OUT"
  fi
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
