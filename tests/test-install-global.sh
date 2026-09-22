#!/usr/bin/env bash
# HOME-scoped installer tests — install.sh --global, and --codex refusing.
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
#   G6  --codex is refused, exits non-zero, and writes nothing under HOME
#   G7  skills/cadence/references/global-block.md is a byte copy of the template
#   G8  (removed with the Codex layer: the skill copy and its marker)
#   G9  (removed with the Codex layer: the ~/.codex/hooks.json merge)
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

# The --codex probes that lived here (block parity with --global, the skill
# copy and its .orch-installed marker, the ~/.codex/hooks.json merge and the
# opt-in Codex evidence hooks) went with the Codex layer itself: install.sh
# refuses --codex now and none of those files ship. G6 below pins the refusal.

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
section "G6 — --codex is refused, and the refusal writes nothing"
#
# install.sh --codex used to render a block into ~/.codex/AGENTS.md, copy the
# cadence skill into ~/.agents/skills/ and merge an adapter into
# ~/.codex/hooks.json. That layer was removed. The sections that asserted each
# of those writes are gone with it; what still has to hold is that the flag
# fails closed and touches nothing — the same invariant G13/G15 protected when
# the refusal came from a malformed hooks.json instead of from the flag.
# ------------------------------------------------------------
H14=$(new_home)
mkdir -p "$H14/.codex"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/true"}]}]}}' \
  > "$H14/.codex/hooks.json"
cp "$H14/.codex/hooks.json" "$TMP/codex-hooks.orig"

if run_install "$H14" --codex; then
  fail "--codex exits non-zero" "exit 0 — it is supposed to refuse"
else
  ok "--codex exits non-zero"
fi
if printf '%s' "$OUT" | grep -q '^refused: --codex is no longer supported'; then
  ok "the refusal is a refused: line that says the flag is gone"
else
  fail "the refusal names the flag" "$OUT"
fi
if [[ ! -e "$H14/.codex/AGENTS.md" ]]; then
  ok "no block was rendered into the Codex global file"
else
  fail "no block was rendered into the Codex global file" "AGENTS.md was written anyway"
fi
if [[ ! -e "$H14/.agents" ]]; then
  ok "no skill copy landed in the user skills directory"
else
  fail "no skill copy landed in the user skills directory" "$(ls -R "$H14/.agents")"
fi
if cmp -s "$TMP/codex-hooks.orig" "$H14/.codex/hooks.json"; then
  ok "a pre-existing ~/.codex/hooks.json is byte-identical after the refusal"
else
  fail "~/.codex/hooks.json is byte-identical after the refusal" \
       "$(cat "$H14/.codex/hooks.json")"
fi
if [[ ! -e "$H14/.codex/hooks.json.bak" ]]; then
  ok "the refusal writes no backup"
else
  fail "the refusal writes no backup" "a .bak appeared"
fi
if [[ ! -e "$H14/.claude/CLAUDE.md" ]]; then
  ok "the Claude side is untouched by a refused --codex"
else
  fail "the Claude side is untouched by a refused --codex" "it wrote ~/.claude/CLAUDE.md"
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
