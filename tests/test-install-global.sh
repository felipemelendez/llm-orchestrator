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
#   G8  --codex removes a marked skill copy an earlier --codex wrote, keeps
#       the person's files inside it, and leaves an unmarked skill alone
#   G9  --codex writes only ~/.codex/AGENTS.md and prints the plugin commands
#   G10 --check's "layers present" report reads HOME from the environment,
#       and names the Codex plugin and anything an earlier --codex left
#   G11 a marker pair the person wrote is not this installer's region
#   G12 a dotfiles-managed link is written through, not over
#   G13 --codex refuses before it writes, and a hooks.json it cannot read is
#       named and left alone
#   G14 with the plugin installed, --codex removes only this plugin's hook
#       entries from ~/.codex/hooks.json, keeps the first backup, and a second
#       run changes nothing; without the plugin it removes nothing
#   G16 the plugin's Stop command runs against a rollout fixture
#   G17 with CODEX_BIN set: a real plugin install, then Codex's hooks/list and
#       skills/list show each hook and the skill once, fresh and after an upgrade
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
# ------------------------------------------------------------
section "G6/G8/G9 — --codex: the block only, and the plugin's commands"
# ------------------------------------------------------------
extract_block() {  # <file> -> the marked region, markers included
  awk -v s="$START" -v e="$END" '
    index($0,s){on=1} on{print} index($0,e){on=0}' "$1"
}
H5=$(new_home)
run_install "$H5" --global >/dev/null 2>&1
if run_install "$H5" --codex; then
  ok "--codex exits 0 on a fresh home"
else
  fail "--codex exits 0 on a fresh home" "$OUT"
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
if [[ "$(ls -A "$H5/.codex")" == "AGENTS.md" && ! -e "$H5/.agents" ]]; then
  ok "--codex writes only ~/.codex/AGENTS.md: no hooks.json, no skill copy, no config.toml"
else
  fail "--codex writes only ~/.codex/AGENTS.md" "$(cd "$H5" && find .codex .agents 2>/dev/null | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -qF "codex plugin marketplace add $ROOT" \
   && printf '%s' "$OUT" | grep -qF 'codex plugin add llm-orchestrator@llm-orchestrator'; then
  ok "--codex prints the two plugin commands that install the skill and the hooks"
else
  fail "--codex prints the two plugin commands" "$OUT"
fi
cp "$H5/.codex/AGENTS.md" "$TMP/h5.agents"
run_install "$H5" --codex >/dev/null 2>&1
if cmp -s "$TMP/h5.agents" "$H5/.codex/AGENTS.md" && printf '%s' "$OUT" | grep -q 'unchanged'; then
  ok "a second --codex changes nothing and says so"
else
  fail "a second --codex changes nothing and says so" "$OUT"
fi

# What `codex plugin add` records in config.toml.
record_plugin() { mkdir -p "$1/.codex"; printf '[plugins."llm-orchestrator@llm-orchestrator"]\nenabled = true\n' > "$1/.codex/config.toml"; }
# A folder that looks like an earlier llm-orchestrator checkout.
old_checkout() {  # old_checkout <dir>
  mkdir -p "$1/.claude-plugin" "$1/scripts/hooks"
  printf '{"name": "llm-orchestrator", "version": "0.9.0"}\n' > "$1/.claude-plugin/plugin.json"
}
# What an earlier install.sh --codex wrote: a marked skill copy with the task
# helper beside it, and four hook entries in ~/.codex/hooks.json pointing at
# this checkout. <extra-json> is a hooks object of the person's own to merge in.
# The plugin is recorded as installed; the tests of an upgrade without it
# change config.toml.
old_install() {  # old_install <home> [<extra hooks json>]
  local h="$1" extra="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  mkdir -p "$h/.codex" "$h/.agents/skills"
  cp -R "$ROOT/skills/cadence" "$h/.agents/skills/cadence"
  mkdir -p "$h/.agents/skills/cadence/scripts/lib"
  cp "$ROOT/scripts/lib/orch-task-resources.py" "$h/.agents/skills/cadence/scripts/lib/"
  printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' > "$h/.agents/skills/cadence/.orch-installed"
  python3 - "$h/.codex/hooks.json" "$ROOT" "$extra" <<'PY'
import json, shlex, sys
path, root, extra = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
cmd = lambda name: {"type": "command", "command": shlex.join(["bash", root + "/scripts/hooks/" + name]), "timeout": 10}
hooks = {event: list(groups) for event, groups in extra.items()}
hooks.setdefault("PreToolUse", []).extend(
    {"matcher": m, "hooks": [cmd("codex-cadence-adapter.sh")]} for m in ("Bash", "apply_patch"))
hooks.setdefault("Stop", []).append({"hooks": [cmd("codex-verify-gate.sh"), cmd("orch-task-cleanup.sh")]})
json.dump({"hooks": hooks}, open(path, "w"), indent=2)
PY
  record_plugin "$h"
}
# How many entries of ours a hooks file still carries.
ours_in() { python3 "$ROOT/scripts/lib/codex-old-hooks.py" count "$1" "$ROOT"; }

SNAP="$TMP/snap.py"
cat > "$SNAP" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        try:
            st = os.lstat(path)
        except OSError:
            rows.append("%s unreadable" % rel)
            continue
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
unchanged() {  # unchanged <label> <before> <after>
  if [[ "$2" == "$3" ]]; then ok "$1"
  else fail "$1" "$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -8 | tr '\n' ' ')"; fi
}

# ------------------------------------------------------------
section "G14 — upgrading from an earlier --codex removes its hooks and skill copy"
# ------------------------------------------------------------
H17=$(new_home)
old_install "$H17" '{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/true"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/false"}]}]}'
cp "$H17/.codex/hooks.json" "$TMP/h17.orig"
if run_install "$H17" --codex; then ok "--codex over an earlier install exits 0"
else fail "--codex over an earlier install exits 0" "$OUT"; fi
[[ "$(ours_in "$H17/.codex/hooks.json")" == "0" ]] \
  && ok "no hook entry of ours is left in ~/.codex/hooks.json" \
  || fail "no hook entry of ours is left" "$(cat "$H17/.codex/hooks.json")"
grep -q '/bin/true' "$H17/.codex/hooks.json" && grep -q '/bin/false' "$H17/.codex/hooks.json" \
  && ok "the person's own PreToolUse and Stop entries survive" \
  || fail "the person's own entries survive" "$(cat "$H17/.codex/hooks.json")"
cmp -s "$TMP/h17.orig" "$H17/.codex/hooks.json.bak" \
  && ok "the backup is the file exactly as it was" \
  || fail "the backup is the file exactly as it was" "$(ls "$H17/.codex")"
[[ ! -e "$H17/.agents/skills/cadence" ]] \
  && ok "the marked skill copy is removed" \
  || fail "the marked skill copy is removed" "$(cd "$H17/.agents/skills" && find cadence | head -5 | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q 'removed 4 hook entries' && printf '%s' "$OUT" | grep -q 'removed the skill copy' \
  && ok "the run says what it removed" || fail "the run says what it removed" "$OUT"
BEFORE=$(snap "$H17")
run_install "$H17" --codex >/dev/null 2>&1
AFTER=$(snap "$H17")
unchanged "a second run changes nothing and writes no second backup" "$BEFORE" "$AFTER"

# Without the plugin, removing the old install would leave Codex with no
# checks: nothing is removed, the block is written, and the run says why.
for plugin_state in absent disabled; do
  H60=$(new_home); old_install "$H60"
  if [[ "$plugin_state" == absent ]]; then rm "$H60/.codex/config.toml"
  else printf '[plugins."llm-orchestrator@llm-orchestrator"]\nenabled = false\n' > "$H60/.codex/config.toml"; fi
  BEFORE=$(snap "$H60/.agents"); cp "$H60/.codex/hooks.json" "$TMP/h60.before"
  if run_install "$H60" --codex; then ok "--codex with the plugin $plugin_state exits 0"
  else fail "--codex with the plugin $plugin_state exits 0" "$OUT"; fi
  if cmp -s "$TMP/h60.before" "$H60/.codex/hooks.json" && [[ ! -e "$H60/.codex/hooks.json.bak" ]]; then
    unchanged "with the plugin $plugin_state, the old hooks and the skill copy are kept" "$BEFORE" "$(snap "$H60/.agents")"
  else
    fail "with the plugin $plugin_state, the old hooks are kept" "$(ls "$H60/.codex")"
  fi
  grep -qF "$START" "$H60/.codex/AGENTS.md" && printf '%s' "$OUT" | grep -q 'add the plugin first' \
    && ok "the block is written and the run says to add the plugin first, then run --codex again ($plugin_state)" \
    || fail "the run says to add the plugin first ($plugin_state)" "$OUT"
done

# A hooks file with nothing of ours is not rewritten and gets no backup.
H7=$(new_home)
mkdir -p "$H7/.codex"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/false"}]}]}}' > "$H7/.codex/hooks.json"
cp "$H7/.codex/hooks.json" "$TMP/h7.orig"
run_install "$H7" --codex >/dev/null 2>&1
cmp -s "$TMP/h7.orig" "$H7/.codex/hooks.json" && [[ ! -e "$H7/.codex/hooks.json.bak" ]] \
  && ok "a hooks file with nothing of ours is byte-identical, with no backup" \
  || fail "a hooks file with nothing of ours is left alone" "$(ls "$H7/.codex")"

# v0.8/v0.9 registered codex-evidence.py on every event.
H21=$(new_home); record_plugin "$H21"; old_checkout "$H21/old"
cat > "$H21/.codex/hooks.json.in" <<'STALE'
{"hooks":{
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/scripts/hooks/codex-cadence-adapter.sh"}]},
                {"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}],"matcher":"Bash|apply_patch"}],
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "PostToolUse":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}],"matcher":"Bash|apply_patch|write_stdin"},
                 {"matcher":"Bash","hooks":[{"type":"command","command":"/home/me/mine.sh"}]},
                 {"matcher":"Bash","hooks":[{"type":"command","command":"bash /home/me/tools/scripts/hooks/codex-verify-gate.sh"}]}],
  "SubagentStart":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "SubagentStop":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]}],
  "Stop":[{"hooks":[{"type":"command","command":"/opt/python3.14 /old/scripts/hooks/codex-evidence.py","timeout":10}]},
          {"hooks":[{"type":"command","command":"bash /old/scripts/hooks/orch-task-cleanup.sh","timeout":10}]}]}}
STALE
sed "s|/old/|$H21/old/|g" "$H21/.codex/hooks.json.in" > "$H21/.codex/hooks.json"; rm "$H21/.codex/hooks.json.in"
run_install "$H21" --codex >/dev/null 2>&1
! grep -q "$H21/old/" "$H21/.codex/hooks.json" \
  && ok "every entry of the retired evidence hook and every stale path of ours is gone" \
  || fail "stale entries removed" "$(grep -n "$H21/old/" "$H21/.codex/hooks.json")"
grep -q '/home/me/mine.sh' "$H21/.codex/hooks.json" && grep -q '/home/me/tools/scripts/hooks/codex-verify-gate.sh' "$H21/.codex/hooks.json" \
  && ok "the person's own PostToolUse hooks survive, including one at another scripts/hooks/codex-verify-gate.sh" \
  || fail "the person's own PostToolUse hook survives" "$(cat "$H21/.codex/hooks.json")"
python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; sys.exit(0 if set(h) == {"PostToolUse"} else 1)' "$H21/.codex/hooks.json" \
  && ok "events left with no entries are dropped" \
  || fail "events left with no entries are dropped" "$(cat "$H21/.codex/hooks.json")"

# Ownership is the invoked script's name AND its home, never an argument.
H44=$(new_home); record_plugin "$H44"; old_checkout "$H44/old"
mkdir -p "$H44/my-hooks"
printf '#!/bin/sh\necho FOREIGN_HOOK_RAN\n' > "$H44/my-hooks/codex-verify-gate.sh"
python3 -c 'import json,sys
root, home = sys.argv[1], sys.argv[2]
json.dump({"hooks": {"Stop": [{"hooks": [
  {"type": "command", "command": "env LANG=C bash %s/scripts/hooks/codex-verify-gate.sh" % root},
  {"type": "command", "command": "bash -c %s/scripts/hooks/codex-verify-gate.sh" % root},
  {"type": "command", "command": "env python3 %s/old/scripts/hooks/codex-evidence.py" % home},
  {"type": "command", "command": "bash /home/me/audit.sh codex-evidence.py"},
  {"type": "command", "command": "/Users/me/llm-orchestrator-notes/my-own-hook.sh"},
  {"type": "command", "command": "bash -c \"%s/my-hooks/wrap %s/scripts/hooks/codex-verify-gate.sh\"" % (home, root)},
  {"type": "command", "command": "bash %s/my-hooks/codex-verify-gate.sh" % home}]}]}}, open(home + "/.codex/hooks.json", "w"), indent=2)' \
  "$ROOT" "$H44"
BEFORE=$(snap "$H44/my-hooks")
run_install "$H44" --codex >/dev/null 2>&1
unchanged "the person's own hook script is byte-identical after the run" "$BEFORE" "$(snap "$H44/my-hooks")"
[[ "$(ours_in "$H44/.codex/hooks.json")" == "0" ]] && ! grep -q "$H44/old/" "$H44/.codex/hooks.json" \
  && ok "env-prefixed and -c entries of ours are removed" \
  || fail "env-prefixed and -c entries of ours are removed" "$(cat "$H44/.codex/hooks.json")"
n_kept=$(python3 -c 'import json,sys; print(sum(len(g["hooks"]) for g in json.load(open(sys.argv[1]))["hooks"]["Stop"]))' "$H44/.codex/hooks.json")
grep -q 'audit.sh codex-evidence.py' "$H44/.codex/hooks.json" && grep -q 'my-own-hook.sh' "$H44/.codex/hooks.json" \
  && grep -q 'my-hooks/wrap ' "$H44/.codex/hooks.json" && grep -q "$H44/my-hooks/codex-verify-gate.sh\"" "$H44/.codex/hooks.json" \
  && [[ "$n_kept" == "4" ]] \
  && ok "the person's four entries survive: an argument, a name, a wrapper and a same-named script are not ours" \
  || fail "the person's four entries survive" "$(cat "$H44/.codex/hooks.json")"

# ------------------------------------------------------------
section "G8 — the skill copy: only a marked copy, and only what this plugin ships"
# ------------------------------------------------------------
H6=$(new_home); record_plugin "$H6"
mkdir -p "$H6/.agents/skills/cadence"
printf 'someone else\n' > "$H6/.agents/skills/cadence/SKILL.md"
BEFORE=$(snap "$H6/.agents")
if run_install "$H6" --codex; then ok "an unmarked cadence skill does not stop the run"
else fail "an unmarked cadence skill does not stop the run" "$OUT"; fi
unchanged "the unmarked skill is left exactly as it was" "$BEFORE" "$(snap "$H6/.agents")"
printf '%s' "$OUT" | grep -q 'did not write' \
  && ok "and the run says it left that skill in place" || fail "the run names the unmarked skill" "$OUT"

H18=$(new_home)
old_install "$H18"
printf 'my own note\n' > "$H18/.agents/skills/cadence/MY-NOTES.md"
mkdir -p "$H18/elsewhere"; printf 'mine\n' > "$H18/elsewhere/x.md"
rm "$H18/.agents/skills/cadence/references/global-block.md"
ln -s "$H18/elsewhere/x.md" "$H18/.agents/skills/cadence/references/global-block.md"
run_install "$H18" --codex
[[ -f "$H18/.agents/skills/cadence/MY-NOTES.md" && -L "$H18/.agents/skills/cadence/references/global-block.md" ]] \
  && ok "a person's file and a person's link inside the copy are kept" \
  || fail "a person's file and link inside the copy are kept" "$(cd "$H18/.agents/skills" && find cadence | tr '\n' ' ')"
[[ ! -e "$H18/.agents/skills/cadence/SKILL.md" && ! -e "$H18/.agents/skills/cadence/.orch-installed" \
   && ! -e "$H18/.agents/skills/cadence/scripts" ]] \
  && ok "every file this plugin shipped, and the marker, are removed" \
  || fail "shipped files removed" "$(cd "$H18/.agents/skills" && find cadence | tr '\n' ' ')"
printf '%s' "$OUT" | grep -q 'MY-NOTES.md' && printf '%s' "$OUT" | grep -q 'references/global-block.md' \
  && ok "and the run names what it kept" || fail "the run names what it kept" "$OUT"

# A linked skill directory: the copy behind it is removed, then the link.
H50=$(new_home)
old_install "$H50"
mv "$H50/.agents/skills/cadence" "$H50/real-copy"
ln -s "$H50/real-copy" "$H50/.agents/skills/cadence"
run_install "$H50" --codex
[[ ! -e "$H50/real-copy" && ! -L "$H50/.agents/skills/cadence" ]] \
  && ok "a linked copy is removed behind the link, and the link with it" \
  || fail "a linked copy is removed" "$OUT"

# ------------------------------------------------------------
section "G13 — --codex refuses before it writes, and says so"
# ------------------------------------------------------------
refuses() {  # refuses <label> <home> -> the run refuses and HOME is unchanged
  local before after
  before=$(snap "$2")
  if run_install "$2" --codex; then
    fail "$1" "exit 0 — $OUT"
  elif ! printf '%s' "$OUT" | grep -q '^refused:'; then
    fail "$1" "no refused: line — $OUT"
  else
    after=$(snap "$2")
    unchanged "$1, and nothing under HOME changed" "$before" "$after"
  fi
}

# The block render's own refusals, with an earlier install in place.
for shape in duplicate dangling foreign directory; do
  H24=$(new_home); old_install "$H24"
  case "$shape" in
    duplicate) { cat "$TEMPLATE"; printf '\n'; cat "$TEMPLATE"; } > "$H24/.codex/AGENTS.md" ;;
    dangling)  ln -s "$H24/nowhere/AGENTS.md" "$H24/.codex/AGENTS.md" ;;
    foreign)   printf '%s\nmy own text between the markers\n%s\n' "$START" "$END" > "$H24/.codex/AGENTS.md" ;;
    directory) mkdir "$H24/.codex/AGENTS.md" ;;
  esac
  refuses "--codex refuses an AGENTS.md it cannot render ($shape)" "$H24"
done
printf '%s' "$OUT" | grep -qi 'layers present' \
  && ok "the layers report prints on the refusal path too" || fail "the layers report prints on refusal" "$OUT"

H35=$(new_home); old_install "$H35"
mkdir -p "$H35/ro"; ln -s "$H35/ro/AGENTS.md" "$H35/.codex/AGENTS.md"; chmod 500 "$H35/ro"
refuses "--codex refuses an AGENTS.md linked into a read-only directory" "$H35"
chmod 700 "$H35/ro"

H16=$(new_home); mkdir -p "$H16/.codex"; chmod 500 "$H16/.codex"
refuses "--codex refuses a read-only ~/.codex" "$H16"
chmod 700 "$H16/.codex"

H54=$(new_home); ln -s "$H54/nowhere" "$H54/.codex"
refuses "--codex refuses a dangling ~/.codex link" "$H54"

# Old entries in a hooks file that cannot be rewritten in place.
H26=$(new_home); old_install "$H26"
mkdir -p "$H26.outside"; mv "$H26/.codex/hooks.json" "$H26.outside/hooks.json"
ln -s "$H26/../$(basename "$H26").outside/hooks.json" "$H26/.codex/hooks.json"
cp "$H26.outside/hooks.json" "$TMP/h26.before"
refuses "--codex refuses old entries in a hooks.json linked outside HOME through .." "$H26"
cmp -s "$TMP/h26.before" "$H26.outside/hooks.json" && ok "and the outside file is untouched" \
  || fail "the outside file is untouched" "$(cat "$H26.outside/hooks.json")"
rm -rf "$H26.outside"

H28=$(new_home); old_install "$H28"
mkdir -p "$H28/readonly"; mv "$H28/.codex/hooks.json" "$H28/readonly/hooks.json"
ln -s "$H28/readonly/hooks.json" "$H28/.codex/hooks.json"; chmod 500 "$H28/readonly"
refuses "--codex refuses old entries in a hooks.json whose directory is read-only" "$H28"
chmod 700 "$H28/readonly"

H45=$(new_home); old_install "$H45"
ln -s "$H45/.codex/hooks.json" "$H45/.codex/AGENTS.md"
refuses "--codex refuses an AGENTS.md that is the hooks file it must clean" "$H45"

# A marked copy that cannot be emptied, or that lies outside HOME.
H37=$(new_home); old_install "$H37"; chmod 500 "$H37/.agents/skills/cadence/scripts"
refuses "--codex refuses a marked copy holding a read-only directory" "$H37"
chmod 700 "$H37/.agents/skills/cadence/scripts"

H48=$(new_home); old_install "$H48"; chmod 600 "$H48/.agents/skills/cadence"
refuses "--codex refuses a skill copy it cannot enter" "$H48"
chmod 700 "$H48/.agents/skills/cadence"

H31=$(new_home); old_install "$H31"
mv "$H31/.agents" "$H31.agents-outside"; ln -s "$H31.agents-outside" "$H31/.agents"
BEFORE_OUT=$(snap "$H31.agents-outside")
refuses "--codex refuses a marked copy reached through a link outside HOME" "$H31"
unchanged "and the copy outside HOME is untouched" "$BEFORE_OUT" "$(snap "$H31.agents-outside")"
rm -rf "$H31.agents-outside"

# A hooks file that is not JSON cannot be loaded by Codex either: it is named,
# left alone, and the block is still rendered.
for body in 'not json at all {{{' '[{"matcher":"Bash"}]'; do
  H15=$(new_home); record_plugin "$H15"
  printf '%s\n' "$body" > "$H15/.codex/hooks.json"
  cp "$H15/.codex/hooks.json" "$TMP/h15.before"
  run_install "$H15" --codex
  cmp -s "$TMP/h15.before" "$H15/.codex/hooks.json" && grep -qF "$START" "$H15/.codex/AGENTS.md" \
     && printf '%s' "$OUT" | grep -q 'not checked for entries' \
    && ok "a hooks.json that is not a hooks object is named and left alone ($body)" \
    || fail "a hooks.json that is not a hooks object is named and left alone ($body)" "$OUT"
done

# A planted temp-file link and a dangling backup link are never followed.
H36=$(new_home); old_install "$H36"
mkdir -p "$H36.victim"; printf 'unique user work\n' > "$H36.victim/data"
ln -s "$H36.victim/data" "$H36/.codex/hooks.json.orch-merge.tmp"
ln -s "$H36.victim/backup" "$H36/.codex/hooks.json.bak"
run_install "$H36" --codex >/dev/null 2>&1
[[ "$(cat "$H36.victim/data")" == "unique user work" && ! -e "$H36.victim/backup" \
   && -f "$H36/.codex/hooks.json" && ! -L "$H36/.codex/hooks.json" && "$(ours_in "$H36/.codex/hooks.json")" == "0" ]] \
  && ok "a planted temp-file link and a dangling backup link are not followed" \
  || fail "planted links are not followed" "$(ls -la "$H36/.codex" "$H36.victim")"
rm -rf "$H36.victim"

# ------------------------------------------------------------
section "G10b — the layers report names the plugin and any leftovers"
# ------------------------------------------------------------
H19=$(new_home); old_install "$H19"
run_install "$H19" --check >/dev/null 2>&1
printf '%s' "$OUT" | grep 'earlier --codex' | grep -q '4 hook entries' \
  && printf '%s' "$OUT" | grep 'earlier --codex' | grep -q 'skill copy' \
  && ok "the report names the hook entries and the skill copy an earlier --codex left" \
  || fail "the report names the leftovers" "$OUT"
run_install "$H19" --codex >/dev/null 2>&1
run_install "$H19" --check >/dev/null 2>&1
printf '%s' "$OUT" | grep 'earlier --codex' | grep -q 'none$' \
  && ok "after --codex it reports none" || fail "after --codex it reports none" "$OUT"
printf '%s' "$OUT" | grep 'Codex plugin' | grep -q 'yes$' \
  && ok "the report says the Codex plugin is installed when config.toml names it" || fail "plugin line says yes" "$OUT"
run_install "$(new_home)" --check >/dev/null 2>&1
printf '%s' "$OUT" | grep 'Codex plugin' | grep -q 'no$' \
  && ok "and no in a home without it" || fail "plugin line says no" "$OUT"

# ------------------------------------------------------------
section "G16 — the plugin's Stop command runs against a rollout fixture"
# ------------------------------------------------------------
STOP_CMD=$(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))["hooks"]["hooks"]
for g in m["Stop"]:
    for h in g["hooks"]:
        if "codex-verify-gate.sh" in h["command"]: print(h["command"].replace("${PLUGIN_ROOT}", sys.argv[2]))' \
  "$ROOT/.codex-plugin/plugin.json" "$ROOT")
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
H20=$(new_home)
stop_payload t1 | env HOME="$H20" bash -c "$STOP_CMD" > "$TMP/g1.out" 2> "$TMP/g1.err"; rc1=$?
stop_payload t2 | env HOME="$H20" bash -c "$STOP_CMD" > "$TMP/g2.out" 2> "$TMP/g2.err"; rc2=$?
if [[ $rc1 -eq 0 ]] && grep -q '"decision": "block"' "$TMP/g1.out" && grep -q 'no check ran and passed' "$TMP/g1.out"; then
  ok "the plugin's Stop command sends the agent back on a PASS with no check"
else
  fail "the plugin's Stop command sends the agent back on a PASS with no check" "rc=$rc1 out=$(cat "$TMP/g1.out") err=$(cat "$TMP/g1.err")"
fi
if [[ $rc2 -eq 0 && ! -s "$TMP/g2.out" ]]; then
  ok "the plugin's Stop command is silent on a PASS with a passing check"
else
  fail "the plugin's Stop command is silent on a PASS with a passing check" "rc=$rc2 out=$(cat "$TMP/g2.out")"
fi
if ! grep -q 'systemMessage' "$TMP/g1.out" "$TMP/g2.out" && [[ ! -s "$TMP/g1.err" && ! -s "$TMP/g2.err" ]]; then
  ok "nothing is addressed to the person: no systemMessage, nothing on stderr"
else
  fail "nothing is addressed to the person" "$(cat "$TMP/g1.out" "$TMP/g1.err" "$TMP/g2.err")"
fi

# ------------------------------------------------------------
section "G17 — live Codex: each hook and the skill are listed once"
#
# A real `codex plugin add` from this checkout into a temporary CODEX_HOME,
# then the app server's hooks/list and skills/list. No model call is made.
# Codex is optional: with no CLI on the PATH these probes are skipped, even
# under ORCH_REQUIRE_DEPS=1, so CI needs no Codex. Setting CODEX_BIN asks for
# them, and then a missing CLI is a failure.
# ------------------------------------------------------------
CODEX_ASKED="${CODEX_BIN:+1}"
CODEX_BIN="${CODEX_BIN:-codex}"
if CODEX_VERSION=$("$CODEX_BIN" --version 2>/dev/null) && [[ "$CODEX_VERSION" == codex-cli* ]]; then
  printf '  %s%s%s\n' "$DIM" "$CODEX_VERSION" "$RESET"
  codex_lists() {  # codex_lists <home> -> hooks and cadence skills, one per line
    mkdir -p "$1/proj"
    env HOME="$1" CODEX_HOME="$1/.codex" python3 "$ROOT/tests/lib/codex-app-server-list.py" "$CODEX_BIN" "$1/proj"
  }
  plugin_install() {  # plugin_install <home>
    mkdir -p "$1/.codex"
    env HOME="$1" CODEX_HOME="$1/.codex" "$CODEX_BIN" plugin marketplace add "$ROOT" >/dev/null 2>&1 \
      && env HOME="$1" CODEX_HOME="$1/.codex" "$CODEX_BIN" plugin add llm-orchestrator@llm-orchestrator >/dev/null 2>&1
  }
  WANT="hook preToolUse Bash plugin codex-cadence-adapter.sh
hook preToolUse apply_patch plugin codex-cadence-adapter.sh
hook stop None plugin codex-verify-gate.sh
hook stop None plugin orch-task-cleanup.sh
skill llm-orchestrator:cadence"
  once() {  # once <label> <home>
    local got
    got=$(codex_lists "$2" | sed -E 's|^(skill [^ ]+) .*|\1|')
    if [[ "$got" == "$WANT" ]]; then ok "$1"; else fail "$1" "$(printf '%s' "$got" | tr '\n' '|')"; fi
  }
  HA=$(new_home)
  if plugin_install "$HA" && run_install "$HA" --codex; then
    once "a fresh plugin install plus --codex lists each hook and the skill once, all from the plugin" "$HA"
  else
    fail "a fresh plugin install plus --codex" "$OUT"
  fi
  # The upgrade starts from the installer as it was at 5141c9d, the last
  # commit whose --codex copied the skill and merged the hooks.
  OLD_TREE="$TMP/old-5141c9d"; mkdir -p "$OLD_TREE"
  if git -C "$ROOT" archive 5141c9d 2>/dev/null | tar -x -C "$OLD_TREE" 2>/dev/null \
     && [[ -f "$OLD_TREE/scripts/install.sh" ]]; then
  HC=$(new_home)
  env HOME="$HC" bash "$OLD_TREE/scripts/install.sh" --codex >/dev/null 2>&1
  run_install "$HC" --codex >/dev/null 2>&1
  n=$(codex_lists "$HC" | grep -c '^hook .* user ')
  [[ "$n" == "4" ]] && ok "without the plugin, --codex keeps the four hooks the old installer registered" \
    || fail "without the plugin, --codex keeps the old hooks" "found $n user hooks"
  HB=$(new_home)
  env HOME="$HB" bash "$OLD_TREE/scripts/install.sh" --codex >/dev/null 2>&1
  if plugin_install "$HB"; then
    n=$(codex_lists "$HB" | grep -c 'codex-verify-gate.sh')
    [[ "$n" == "2" ]] && ok "before --codex, an earlier install and the plugin list the completion check twice" \
      || fail "before --codex the completion check is listed twice" "found $n"
    run_install "$HB" --codex >/dev/null 2>&1
    once "after --codex, the upgrade lists each hook and the skill once, all from the plugin" "$HB"
  else
    fail "the plugin installs over an earlier --codex" "codex plugin add failed"
  fi
  elif [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    fail "the old installer at 5141c9d" "not in this clone's history"
  else
    printf '  skip the upgrade probes (5141c9d is not in this clone'"'"'s history)\n'
  fi
elif [[ -n "$CODEX_ASKED" ]]; then
  fail "live Codex probes" "CODEX_BIN=$CODEX_BIN is set, but it is not a working Codex CLI"
else
  printf '  skip live Codex probes (no Codex CLI on the PATH; set CODEX_BIN to require them)\n'
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
