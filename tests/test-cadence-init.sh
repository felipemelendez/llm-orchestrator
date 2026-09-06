#!/usr/bin/env bash
# Tests for skills/cadence/scripts/cadence-init.sh — the project-scoped writes
# and the git layer.
#
# The invariant chain this suite pins:
#   - init NEVER overwrites a file the project already has: the four law
#     documents, AGENTS.md, CLAUDE.md and the two git hooks are `kept` when they
#     exist, and the deny rules merge into a settings file rather than replacing
#     it (a tool that can clobber a project's laws while installing the lock on
#     them is worse than no tool);
#   - the deny rules are spelled `Edit(...)` and nothing else — path rules are
#     consulted for Edit and Read only, so a `Write(...)` rule is decoration;
#   - `@AGENTS.md` goes in as the FIRST line of CLAUDE.md and every other byte
#     survives, and the block never lands inside an unclosed code fence;
#   - cadence.json is written LAST, because the lock guard refuses every one of
#     the writes above the moment that file exists;
#   - a second run changes nothing (same shasums, every path line `kept`);
#   - the git layer holds end to end: after `core.hooksPath`, a commit that
#     edits the laws without a numbered ruling is refused, and the same edit
#     lands once the ruling is in the message, recorded in the laws, and the
#     manifest has been rewritten under the unlock.
#
# Bash 3.2 compatible. Never touches the real HOME; every fixture is a
# `mktemp -d` repo.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="${ROOT}/skills/cadence/scripts/cadence-init.sh"
CHECK="${ROOT}/skills/cadence/scripts/orch-cadence-check.sh"
REFS="${ROOT}/skills/cadence/references"
BLOCK="${ROOT}/templates/cadence-global-block.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}

command -v git >/dev/null 2>&1 || skip_suite test-cadence-init 'git unavailable'
command -v python3 >/dev/null 2>&1 || skip_suite test-cadence-init 'python3 unavailable'
if [[ ! -f "$INIT" ]]; then
  printf '%s✗%s missing script: %s\n' "$RED" "$RESET" "$INIT"
  printf '%sFAIL: test-cadence-init — 0 passed, 1 failed.%s\n' "$RED" "$RESET"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# --lock refuses when ANY settings file in scope persists the unlock token, and
# $HOME/.claude/settings.json is in that scope. The operator's own home must not
# decide this suite's outcome, and this suite must never write to it.
REAL_HOME="$HOME"
REAL_HOME_SHA=""
[[ -f "$REAL_HOME/.claude/settings.json" ]] && REAL_HOME_SHA="$(shasum -a 256 "$REAL_HOME/.claude/settings.json" 2>/dev/null | awk '{print $1}')"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1
GIT_ID=(-c user.email=cadence@test -c user.name=cadence)
unset ORCH_CADENCE_UNLOCK
unset ORCH_CADENCE_PYTHON

OUT="$TMP/out.txt"; ERR="$TMP/err.txt"

run() { # run <root> <args...> -> stdout in $OUT, stderr in $ERR, echoes rc
  local p="$1"; shift
  bash "$INIT" --root "$p" "$@" > "$OUT" 2> "$ERR"; echo $?
}
runu() { # runu <root> <args...> -> the same, with ORCH_CADENCE_UNLOCK=1 set
  local p="$1"; shift
  ORCH_CADENCE_UNLOCK=1 bash "$INIT" --root "$p" "$@" > "$OUT" 2> "$ERR"; echo $?
}
has()  { grep -qF -- "$2" "$1"; }
hasre(){ grep -qE -- "$2" "$1"; }
sha()  { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
mtime(){ stat -f '%Fm' "$1" 2>/dev/null || stat -c '%.9Y' "$1" 2>/dev/null; }
# The line number of the first line of $OUT containing <string>, or empty.
lineof(){ grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
tree_sha() { # every regular file under <dir>, path + content, one digest
  ( cd "$1" && find . -type f ! -path './.git/*' -print0 | sort -z \
      | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}' )
}
mkproj() { mkdir -p "$1"; }
mkrepo() { mkdir -p "$1"; ( cd "$1" && git init -q . ) >/dev/null 2>&1; }

# The conformance battery runs every marker shape through BOTH readers. The
# init's verdict is the absolute assertion; the lock's is measured beside it, so
# a divergence is recorded rather than discovered by a later round. `--lock`
# needs nothing but an enabled cadence.json and the file under test, so the
# probe root is built by hand — the init must never have run over it, or the
# init's own refusal would decide what the lock never saw.
LPN=0
LOCK_SECT_SHA=""; LOCK_SECT_SHA_C=""
LOCK_RC=""
lock_probe() { # <agents-file|""> [<claude-file>] -> LOCK_RC, LOCK_SECT_SHA, LOCK_SECT_SHA_C
  # Never called in a command substitution: the counter and the three results
  # have to survive the call, and a subshell would reuse one probe root and
  # report the second run's "LOCK.sha256 already exists" as the lock's verdict.
  local src="$1" cl="${2:-}" d rc
  LPN=$((LPN+1)); d="$TMP/lockprobe.$LPN"
  mkdir -p "$d/docs/llm-orchestrator"
  printf '{ "schema": 1, "enabled": true }\n' > "$d/docs/llm-orchestrator/cadence.json"
  [[ -n "$src" && -f "$src" ]] && cp "$src" "$d/AGENTS.md"
  [[ -n "$cl" && -f "$cl" ]] && cp "$cl" "$d/CLAUDE.md"
  bash "$CHECK" --root "$d" --lock > "$TMP/lockprobe.log" 2>&1; rc=$?
  LOCK_SECT_SHA=""; LOCK_SECT_SHA_C=""
  if [[ -f "$d/docs/llm-orchestrator/LOCK.sha256" ]]; then
    LOCK_SECT_SHA=$(awk '$2=="AGENTS.md#ORCH:LAWS"{print $1}' "$d/docs/llm-orchestrator/LOCK.sha256")
    LOCK_SECT_SHA_C=$(awk '$2=="CLAUDE.md#ORCH:LAWS"{print $1}' "$d/docs/llm-orchestrator/LOCK.sha256")
  fi
  LOCK_RC="$rc"
}
# The section bytes the lock would hash for a file, computed independently of
# the check script, so an accepted shape is pinned to a SPAN and not only to a
# return code.
sect_sha() { # <file>
  local s
  s=$(awk -v s='<!-- ORCH:LAWS:START -->' -v e='<!-- ORCH:LAWS:END -->' '
    !p && index($0, s) { p=1; print; if (index($0, e)) exit; next }
    p { print; if (index($0, e)) exit }' "$1")
  printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
}

DENY_RULES=(
  'Edit(docs/llm-orchestrator/LAWS.md)'
  'Edit(docs/llm-orchestrator/cadence.json)'
  'Edit(docs/llm-orchestrator/LOCK.sha256)'
  'Edit(.claude/settings.json)'
  'Edit(.githooks/**)'
)

printf '\n%s== a fresh project gets every file, and the lock closes over them ==%s\n' "$DIM" "$RESET"
# SCENE: given a project that has never run the cadence; when cadence-init runs
# with no flags; expect every law document, the block, the import line, the deny
# rules, the git layer, cadence.json LAST, and a manifest the verdict calls OK.
F="$TMP/fresh"; mkrepo "$F"
RC=$(run "$F")
[[ "$RC" == "0" ]] && ok "a fresh project initializes at exit 0" || fail "fresh exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"

MISSING=""
for f in docs/llm-orchestrator/LAWS.md docs/llm-orchestrator/HANDOFF_TEMPLATE.md \
         docs/llm-orchestrator/DESIGN_RULINGS.md docs/llm-orchestrator/TRAPS.md \
         docs/llm-orchestrator/cadence.json docs/llm-orchestrator/LOCK.sha256 \
         AGENTS.md CLAUDE.md .claude/settings.json \
         .githooks/commit-msg .githooks/orch-cadence-check.sh; do
  [[ -f "$F/$f" ]] || MISSING="$MISSING $f"
done
[[ -z "$MISSING" ]] && ok "every file of the cadence exists after one run" || fail "fresh files" "missing:$MISSING"

BAD=""
cmp -s "$REFS/laws.md"           "$F/docs/llm-orchestrator/LAWS.md"            || BAD="$BAD LAWS.md"
cmp -s "$REFS/handoff.md"        "$F/docs/llm-orchestrator/HANDOFF_TEMPLATE.md" || BAD="$BAD HANDOFF_TEMPLATE.md"
cmp -s "$REFS/design-rulings.md" "$F/docs/llm-orchestrator/DESIGN_RULINGS.md"  || BAD="$BAD DESIGN_RULINGS.md"
cmp -s "$REFS/traps.md"          "$F/docs/llm-orchestrator/TRAPS.md"           || BAD="$BAD TRAPS.md"
[[ -z "$BAD" ]] && ok "the four law documents are byte copies of the skill's references" || fail "law doc bytes" "differ:$BAD"

if [[ "$(head -1 "$F/CLAUDE.md")" == "@AGENTS.md" ]]; then ok "CLAUDE.md opens with @AGENTS.md"; else fail "claude import" "$(head -3 "$F/CLAUDE.md")"; fi
if has "$F/AGENTS.md" '<!-- ORCH:LAWS:START -->' && has "$F/AGENTS.md" '<!-- ORCH:LAWS:END -->'; then
  ok "AGENTS.md carries the marked block"; else fail "agents block" "$(cat "$F/AGENTS.md")"; fi

MISS=""
for r in "${DENY_RULES[@]}"; do has "$F/.claude/settings.json" "$r" || MISS="$MISS $r"; done
[[ -z "$MISS" ]] && ok "all five deny rules are present" || fail "deny rules" "missing:$MISS"
if grep -qE '"(Write|MultiEdit|NotebookEdit)\(' "$F/.claude/settings.json"; then
  fail "deny spelling" "a rule names a tool whose path rules are never consulted: $(grep -oE '"(Write|MultiEdit|NotebookEdit)\([^"]*\)"' "$F/.claude/settings.json" | tr '\n' ' ')"
else ok "the rules are spelled Edit(...) and nothing else"; fi
if python3 -m json.tool "$F/.claude/settings.json" >/dev/null 2>&1; then ok "the settings file it wrote is valid JSON"; else fail "settings json" "$(cat "$F/.claude/settings.json")"; fi

cmp -s "$REFS/commit-msg" "$F/.githooks/commit-msg" && ok ".githooks/commit-msg is a byte copy of the reference" || fail "commit-msg bytes" "differs"
cmp -s "$CHECK" "$F/.githooks/orch-cadence-check.sh" && ok ".githooks/orch-cadence-check.sh is a byte copy of the skill's check" || fail "check copy bytes" "differs"
if [[ -x "$F/.githooks/commit-msg" && -x "$F/.githooks/orch-cadence-check.sh" ]]; then ok "both hooks are executable"; else fail "hook mode" "$(ls -l "$F/.githooks")"; fi

if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("schema")==1 and d.get("enabled") is True else 1)' "$F/docs/llm-orchestrator/cadence.json"; then
  ok 'cadence.json carries "schema": 1 and "enabled": true'; else fail "cadence.json shape" "$(cat "$F/docs/llm-orchestrator/cadence.json")"; fi

has "$OUT" 'git config core.hooksPath .githooks' && ok "the report prints the hooksPath one-liner" || fail "hooksPath line" "$(cat "$OUT")"
hasre "$OUT" 'cadence: LAWS\.md.*lock OK' && ok "the verdict in the report says lock OK" || fail "verdict line" "$(cat "$OUT")"
has "$OUT" 'created docs/llm-orchestrator/LAWS.md' && ok "the report says created for a file it wrote" || fail "created line" "$(cat "$OUT")"
has "$OUT" '<PLACEHOLDER>' && ok "a fresh init reminds the reader to fill the placeholders in" || fail "placeholder reminder" "$(cat "$OUT")"
# cadence.json LAST: the lock guard refuses writes to settings.json and
# .githooks the moment it exists, so an init that wrote it early would be
# refused by its own enforcement on any project that re-runs it. Observed on
# the FILESYSTEM, not in the report's prose — a report line can be printed in
# any order its author likes; a write cannot be moved without moving its mtime.
LATER=""
CJ_MT=$(mtime "$F/docs/llm-orchestrator/cadence.json")
for f in docs/llm-orchestrator/LAWS.md docs/llm-orchestrator/TRAPS.md AGENTS.md CLAUDE.md \
         .claude/settings.json .githooks/commit-msg .githooks/orch-cadence-check.sh; do
  M=$(mtime "$F/$f")
  awk -v a="$M" -v b="$CJ_MT" 'BEGIN{ exit !(a+0 > b+0) }' && LATER="$LATER $f"
done
if [[ -n "$CJ_MT" && -z "$LATER" ]]; then ok "cadence.json is written after every other file (mtimes, not report order)"; else fail "write order" "cadence.json mtime=${CJ_MT:-none}; written later:$LATER"; fi

printf '\n%s== the second run changes nothing ==%s\n' "$DIM" "$RESET"
# SCENE: given an initialized project; when cadence-init runs again; expect the
# same bytes everywhere and a report of nothing but `kept`.
BEFORE=$(tree_sha "$F")
RC=$(run "$F")
AFTER=$(tree_sha "$F")
[[ "$RC" == "0" ]] && ok "a re-run exits 0" || fail "re-run exit" "rc=$RC out=$(cat "$OUT")"
[[ "$BEFORE" == "$AFTER" ]] && ok "a re-run changes not one byte in the project" || fail "re-run mutated" "$BEFORE != $AFTER"
NOTKEPT=$(grep -E '^(created|merged|replaced|appended|inserted) ' "$OUT" | tr '\n' ' ')
[[ -z "$NOTKEPT" ]] && ok "every path line of a re-run says kept" || fail "re-run lines" "$NOTKEPT"
[[ -f "$F/.claude/settings.json.bak" ]] && fail "spurious bak" "a re-run that changes nothing wrote a .bak" || ok "a re-run that changes nothing writes no .bak"

printf '\n%s== an existing CLAUDE.md keeps every byte it had ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose CLAUDE.md is a real file with a fenced block;
# when init runs; expect @AGENTS.md prepended as line 1 and the rest identical.
C="$TMP/claude"; mkrepo "$C"
printf '# CLAUDE.md\n\nHouse rules.\n\n```bash\n@AGENTS.md is a decoy inside a fence\n```\n\nTail.\n' > "$C/CLAUDE.md"
cp "$C/CLAUDE.md" "$TMP/claude.orig"
RC=$(run "$C")
[[ "$RC" == "0" ]] && ok "a project with a CLAUDE.md initializes at exit 0" || fail "claude exit" "rc=$RC out=$(cat "$OUT")"
[[ "$(head -1 "$C/CLAUDE.md")" == "@AGENTS.md" ]] && ok "@AGENTS.md is inserted as the first line" || fail "insert" "$(head -2 "$C/CLAUDE.md")"
tail -n +2 "$C/CLAUDE.md" > "$TMP/claude.tail"
cmp -s "$TMP/claude.orig" "$TMP/claude.tail" && ok "every other byte of CLAUDE.md survives" || fail "claude tail" "$(diff "$TMP/claude.orig" "$TMP/claude.tail" | head -5)"
has "$OUT" 'inserted CLAUDE.md' && ok "the report says inserted, not created" || fail "claude report" "$(cat "$OUT")"
RC=$(run "$C")
N=$(grep -c '^@AGENTS.md$' "$C/CLAUDE.md" | tr -d ' ')
[[ "$N" == "1" ]] && ok "a re-run does not insert a second @AGENTS.md" || fail "double import" "count=$N"

printf '\n%s== an existing AGENTS.md is appended to, never rewritten ==%s\n' "$DIM" "$RESET"
# SCENE: given AGENTS.md with the project's own content and no block; when init
# runs; expect the original bytes intact and the block after one blank line.
A="$TMP/agents"; mkrepo "$A"
printf '# Agents\n\nThe project already documents its agents here.\n' > "$A/AGENTS.md"
cp "$A/AGENTS.md" "$TMP/agents.orig"
RC=$(run "$A")
[[ "$RC" == "0" ]] && ok "a project with an AGENTS.md initializes at exit 0" || fail "agents exit" "rc=$RC out=$(cat "$OUT")"
ORIG_LINES=$(wc -l < "$TMP/agents.orig" | tr -d ' ')
head -n "$ORIG_LINES" "$A/AGENTS.md" > "$TMP/agents.head"
cmp -s "$TMP/agents.orig" "$TMP/agents.head" && ok "the project's own AGENTS.md content is untouched" || fail "agents head" "$(diff "$TMP/agents.orig" "$TMP/agents.head" | head -5)"
SEP=$(sed -n "$((ORIG_LINES+1))p" "$A/AGENTS.md")
MARK=$(sed -n "$((ORIG_LINES+2))p" "$A/AGENTS.md")
if [[ -z "$SEP" && "$MARK" == '<!-- ORCH:LAWS:START -->' ]]; then ok "the block follows exactly one blank line"; else fail "separator" "sep=[$SEP] mark=[$MARK]"; fi
cmp -s <(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$A/AGENTS.md") "$BLOCK" \
  && ok "the appended block is the template byte for byte" || fail "block bytes" "differs from $BLOCK"
BEFORE=$(sha "$A/AGENTS.md"); RC=$(run "$A"); AFTER=$(sha "$A/AGENTS.md")
[[ "$BEFORE" == "$AFTER" ]] && ok "an AGENTS.md that already has the block is left alone" || fail "block re-append" "$BEFORE != $AFTER"
has "$OUT" 'kept AGENTS.md' && ok "the report says kept for an AGENTS.md that has the block" || fail "kept agents" "$(cat "$OUT")"

printf '\n%s== an unclosed fence in AGENTS.md is a refusal, not an append ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md whose last code fence was never closed; when init
# runs; expect a refusal that writes nothing — appending there would bury the
# whole block inside a fence, where no agent reads it as instructions.
F2="$TMP/fence"; mkrepo "$F2"
printf '# Agents\n\n```bash\necho "someone forgot to close this"\n' > "$F2/AGENTS.md"
BEFORE=$(sha "$F2/AGENTS.md")
RC=$(run "$F2")
[[ "$RC" == "1" ]] && ok "an unclosed fence exits 1" || fail "fence exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused' && ok "the refusal says refused and why" || fail "fence reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$F2/AGENTS.md")" ]] && ok "the refusal leaves AGENTS.md alone" || fail "fence mutated" "changed"
[[ ! -f "$F2/docs/llm-orchestrator/LAWS.md" && ! -f "$F2/docs/llm-orchestrator/cadence.json" ]] \
  && ok "the refusal writes no other file either (it is a preflight, not a half-init)" \
  || fail "fence partial" "$(ls -R "$F2" 2>/dev/null | tr '\n' ' ')"

printf '\n%s== an existing settings.json is merged, never replaced ==%s\n' "$DIM" "$RESET"
# SCENE: given a settings file with the operator's own keys and its own deny
# list; when init runs; expect the five rules appended, every other key intact,
# and the original preserved as .bak.
S="$TMP/settings"; mkrepo "$S"; mkdir -p "$S/.claude"
cat > "$S/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "env": { "ORCH_HOOK_PROFILE": "full" },
  "permissions": {
    "allow": ["Bash(ls:*)"],
    "deny": ["Bash(rm -rf /:*)"]
  }
}
JSON
cp "$S/.claude/settings.json" "$TMP/settings.orig"
RC=$(run "$S")
[[ "$RC" == "0" ]] && ok "a project with a settings file initializes at exit 0" || fail "settings exit" "rc=$RC out=$(cat "$OUT")"
MISS=""
for r in "${DENY_RULES[@]}"; do has "$S/.claude/settings.json" "$r" || MISS="$MISS $r"; done
[[ -z "$MISS" ]] && ok "the five rules are merged into the existing deny list" || fail "merge rules" "missing:$MISS"
if python3 - "$S/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("model") == "opus", "model lost"
assert d.get("env", {}).get("ORCH_HOOK_PROFILE") == "full", "env lost"
assert d["permissions"]["allow"] == ["Bash(ls:*)"], "allow lost"
assert d["permissions"]["deny"][0] == "Bash(rm -rf /:*)", "the project's own deny rule moved or vanished"
PY
then ok "every other key and the project's own deny rule survive"; else fail "merge integrity" "$(cat "$S/.claude/settings.json")"; fi
cmp -s "$TMP/settings.orig" "$S/.claude/settings.json.bak" && ok "the original is preserved as .claude/settings.json.bak" || fail "bak" "missing or differs"
has "$OUT" 'merged .claude/settings.json' && ok "the report says merged for a settings file it did not create" || fail "merged line" "$(cat "$OUT")"

printf '\n%s== python3 is required to merge a settings file, and says so ==%s\n' "$DIM" "$RESET"
# SCENE: given a project that already has .claude/settings.json and a machine
# with no working python3; when init runs; expect a loud refusal that names the
# dependency and writes nothing — a text-edited settings file is a corrupted one.
P="$TMP/nopy"; mkrepo "$P"; mkdir -p "$P/.claude"
printf '{ "model": "opus" }\n' > "$P/.claude/settings.json"
BEFORE=$(sha "$P/.claude/settings.json")
RC=$(ORCH_CADENCE_PYTHON="$TMP/no-such-python" run "$P")
[[ "$RC" == "1" ]] && ok "no python3 and an existing settings file exits 1" || fail "nopy exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'NEEDS python3' && ok "the refusal names python3 by name" || fail "nopy reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$P/.claude/settings.json")" ]] && ok "the refusal leaves the settings file alone" || fail "nopy mutated" "changed"
[[ ! -f "$P/docs/llm-orchestrator/LAWS.md" ]] && ok "the refusal writes nothing else" || fail "nopy partial" "LAWS.md written"

P2="$TMP/nopy2"; mkrepo "$P2"
RC=$(ORCH_CADENCE_PYTHON="$TMP/no-such-python" run "$P2")
[[ "$RC" == "0" ]] && ok "with no settings file to merge, no python3 is needed" || fail "nopy2 exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
MISS=""
for r in "${DENY_RULES[@]}"; do has "$P2/.claude/settings.json" "$r" || MISS="$MISS $r"; done
[[ -z "$MISS" ]] && ok "the fresh settings file it writes without python3 carries all five rules" || fail "nopy2 rules" "missing:$MISS"
python3 -m json.tool "$P2/.claude/settings.json" >/dev/null 2>&1 && ok "and it is valid JSON" || fail "nopy2 json" "$(cat "$P2/.claude/settings.json")"

printf '\n%s== a differing git hook is kept, and only the unlock replaces it ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose .githooks/commit-msg has been edited by hand;
# when init runs; expect it kept, because silently restoring a hook the operator
# changed is the same class of harm as overwriting their laws.
H="$TMP/hooks"; mkrepo "$H"; mkdir -p "$H/.githooks"
printf '#!/usr/bin/env bash\n# the project wrote its own\nexit 0\n' > "$H/.githooks/commit-msg"
cp "$H/.githooks/commit-msg" "$TMP/hook.orig"
RC=$(run "$H")
[[ "$RC" == "0" ]] && ok "a differing hook does not stop the init" || fail "hook exit" "rc=$RC out=$(cat "$OUT")"
cmp -s "$TMP/hook.orig" "$H/.githooks/commit-msg" && ok "the project's own commit-msg is kept" || fail "hook overwritten" "replaced without the unlock"
has "$OUT" 'kept .githooks/commit-msg' && ok "the report says kept for it" || fail "hook kept line" "$(cat "$OUT")"
# The whole sentence, not just the verb: a reader who is told only `kept` does
# not learn that the hook git will actually run is the project's own one.
has "$OUT" "kept .githooks/commit-msg (it differs from the shipped one — this project's own hook is what git runs; ORCH_CADENCE_UNLOCK=1 replaces it)" \
  && ok "and says whose hook git runs and what replaces it" || fail "hook kept wording" "$(grep -F 'kept .githooks/commit-msg' "$OUT")"
# A kept foreign hook means the git layer is NOT installed: the manifest hashes
# THAT hook, so `lock OK` is true and reads as the layer holding while a laws
# edit with no ruling would land. The report has to say so in both places.
has "$OUT" 'git layer NOT installed' && ok "a kept foreign hook is announced as a git layer that is NOT installed" || fail "no git-layer warning" "$(cat "$OUT")"
has "$OUT" ' · git layer: not installed' && ok "and the verdict line carries · git layer: not installed" || fail "verdict lacks git layer" "$(grep -F 'cadence:' "$OUT")"

RC=$(ORCH_CADENCE_UNLOCK=1 run "$H")
[[ "$RC" == "0" ]] && ok "the unlocked run exits 0" || fail "hook unlock exit" "rc=$RC out=$(cat "$OUT")"
cmp -s "$REFS/commit-msg" "$H/.githooks/commit-msg" && ok "ORCH_CADENCE_UNLOCK=1 replaces it with the shipped hook" || fail "hook not replaced" "still the project's"
has "$OUT" 'replaced .githooks/commit-msg' && ok "the report says replaced" || fail "hook replaced line" "$(cat "$OUT")"
# SCENE: given a project with its own .githooks/commit-msg and a session
# launched ORCH_CADENCE_UNLOCK=1; when init re-runs; expect the person's hook
# preserved — the one variable that gates every re-run must not eat a linter.
cmp -s "$TMP/hook.orig" "$H/.githooks/commit-msg.bak" \
  && ok "the replaced hook is preserved byte for byte at .githooks/commit-msg.bak" \
  || fail "hook bak" "missing or differs: $(ls -1 "$H/.githooks" | tr '\n' ' ')"
has "$OUT" 'replaced .githooks/commit-msg (backup .githooks/commit-msg.bak)' \
  && ok "the report names the backup it made" || fail "hook bak line" "$(cat "$OUT")"
# A second replacement must not eat the first backup.
printf '#!/usr/bin/env bash\n# a second hand-written hook\nexit 0\n' > "$H/.githooks/commit-msg"
cp "$H/.githooks/commit-msg" "$TMP/hook.orig2"
BAK1=$(sha "$H/.githooks/commit-msg.bak")
RC=$(ORCH_CADENCE_UNLOCK=1 run "$H")
[[ "$BAK1" == "$(sha "$H/.githooks/commit-msg.bak")" ]] && ok "an existing .bak is never overwritten" || fail "bak clobbered" "the first backup changed"
cmp -s "$TMP/hook.orig2" "$H/.githooks/commit-msg.bak.1" && ok "the second backup lands at .bak.1" || fail "bak.1" "$(ls -1 "$H/.githooks" | tr '\n' ' ')"

printf '\n%s== --dry-run writes nothing ==%s\n' "$DIM" "$RESET"
# SCENE: given a fresh project; when init runs with --dry-run; expect a plan on
# stdout and an untouched directory.
D="$TMP/dry"; mkrepo "$D"
BEFORE=$(tree_sha "$D")
RC=$(run "$D" --dry-run)
[[ "$RC" == "0" ]] && ok "--dry-run exits 0" || fail "dry exit" "rc=$RC out=$(cat "$OUT")"
[[ "$BEFORE" == "$(tree_sha "$D")" ]] && ok "--dry-run leaves the project byte-identical" || fail "dry mutated" "the plan wrote files"
[[ ! -f "$D/docs/llm-orchestrator/LAWS.md" && ! -f "$D/docs/llm-orchestrator/cadence.json" && ! -f "$D/AGENTS.md" ]] \
  && ok "--dry-run creates none of the files it names" || fail "dry files" "$(ls -R "$D" | tr '\n' ' ')"
has "$OUT" 'would create docs/llm-orchestrator/LAWS.md' && ok "--dry-run prints the plan it would run" || fail "dry plan" "$(cat "$OUT")"

printf '\n%s== --adopt keeps a project that already has its own laws ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose LAWS.md is already written; when init runs with
# --adopt; expect the file kept byte for byte and no placeholder reminder.
AD="$TMP/adopt"; mkrepo "$AD"; mkdir -p "$AD/docs/llm-orchestrator"
printf '# THE LAWS\n\nRuling 3 (2026-01-01, owner): the project already had laws.\n' > "$AD/docs/llm-orchestrator/LAWS.md"
cp "$AD/docs/llm-orchestrator/LAWS.md" "$TMP/adopt.laws"
RC=$(run "$AD" --adopt)
[[ "$RC" == "0" ]] && ok "--adopt exits 0" || fail "adopt exit" "rc=$RC out=$(cat "$OUT")"
cmp -s "$TMP/adopt.laws" "$AD/docs/llm-orchestrator/LAWS.md" && ok "--adopt keeps the project's own laws byte for byte" || fail "adopt overwrote" "the laws changed"
has "$OUT" 'kept docs/llm-orchestrator/LAWS.md' && ok "the report says kept for the adopted laws" || fail "adopt line" "$(cat "$OUT")"
has "$OUT" '<PLACEHOLDER>' && fail "adopt reminder" "--adopt still told the reader to fill in placeholders it did not write" || ok "--adopt prints no placeholder reminder"
hasre "$OUT" 'cadence: LAWS\.md \(ruling 3\)' && ok "the verdict reads the adopted project's own highest ruling" || fail "adopt verdict" "$(cat "$OUT")"
# The four companions are independent: adopting the laws does not skip them.
[[ -f "$AD/docs/llm-orchestrator/TRAPS.md" ]] && ok "--adopt still writes the companions the project lacks" || fail "adopt companions" "TRAPS.md missing"

printf '\n%s== --config is what lands as cadence.json ==%s\n' "$DIM" "$RESET"
# SCENE: given a cadence.json the user confirmed in the conversation; when init
# runs with --config; expect that file's own keys in the project, with schema
# and enabled forced (a config the user edited to "enabled": false would install
# a cadence that is off, and report that it armed one).
G="$TMP/cfg"; mkrepo "$G"
cat > "$TMP/confirmed.json" <<'JSON'
{ "schema": 9, "enabled": false, "notes_dir": "docs/notes", "ticket_re": "^[A-Z]+-[0-9]+:",
  "runner": { "profile": "pytest", "test_cmd": "python3 -m pytest -q" } }
JSON
RC=$(run "$G" --config "$TMP/confirmed.json")
[[ "$RC" == "0" ]] && ok "--config exits 0" || fail "config exit" "rc=$RC out=$(cat "$OUT")"
if python3 - "$G/docs/llm-orchestrator/cadence.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == 1, "schema not forced to 1"
assert d["enabled"] is True, "enabled not forced to true"
assert d["notes_dir"] == "docs/notes", "the user's notes_dir was lost"
assert d["runner"]["profile"] == "pytest", "the user's runner was lost"
PY
then ok "the confirmed config lands with schema 1 and enabled true forced"; else fail "config content" "$(cat "$G/docs/llm-orchestrator/cadence.json")"; fi

printf '\n%s== the git layer end to end ==%s\n' "$DIM" "$RESET"
# SCENE: given an initialized repo with core.hooksPath set; when a commit edits
# the laws with no numbered ruling; expect a refusal and no new commit. Then,
# with the ruling in the message, recorded in the laws, and the manifest rewritten
# under the unlock, expect the same edit to land.
E="$TMP/e2e"; mkrepo "$E"
RC=$(run "$E")
[[ "$RC" == "0" ]] && ok "the e2e fixture initializes" || fail "e2e init" "rc=$RC out=$(cat "$OUT")"
( cd "$E" && git config core.hooksPath .githooks ) >/dev/null 2>&1
( cd "$E" && git add -A && git "${GIT_ID[@]}" commit -q -m "arm the cadence" ) > "$TMP/e2e1.log" 2>&1
RCC=$?
if [[ "$RCC" == "0" ]]; then ok "the arming commit lands (a project with no manifest at HEAD needs no ruling)"; else fail "arming commit" "$(cat "$TMP/e2e1.log")"; fi

printf '\n- the project added a law without saying so\n' >> "$E/docs/llm-orchestrator/LAWS.md"
( cd "$E" && git add -A && git "${GIT_ID[@]}" commit -q -m "tidy the docs" ) > "$TMP/e2e2.log" 2>&1
RCC=$?
SUBJ=$( cd "$E" && git log -1 --format=%s )
if [[ "$RCC" != "0" ]]; then ok "a commit that edits the laws with no ruling is refused"; else fail "unruled commit landed" "$(cat "$TMP/e2e2.log")"; fi
[[ "$SUBJ" == "arm the cadence" ]] && ok "and HEAD is still the arming commit" || fail "e2e head" "git log -1 says: $SUBJ"
has "$TMP/e2e2.log" 'numbered ruling' && ok "the refusal names what is missing" || fail "e2e reason" "$(cat "$TMP/e2e2.log")"

printf 'Ruling 1 (2026-09-05, owner): the laws may say so.\n' >> "$E/docs/llm-orchestrator/LAWS.md"
( cd "$E" && ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$E" --lock ) > "$TMP/e2e_relock.log" 2>&1
( cd "$E" && git add -A && git "${GIT_ID[@]}" commit -q -m "amend the laws

Ruling 1" ) > "$TMP/e2e3.log" 2>&1
RCC=$?
SUBJ=$( cd "$E" && git log -1 --format=%s )
if [[ "$RCC" == "0" && "$SUBJ" == "amend the laws" ]]; then
  ok "with Ruling 1 in the message, in the laws, and a rewritten manifest, the amendment lands"
else
  fail "ruled commit refused" "rc=$RCC subject=$SUBJ relock=$(cat "$TMP/e2e_relock.log") commit=$(cat "$TMP/e2e3.log")"
fi

printf '\n%s== the preflight covers the settings merge too ==%s\n' "$DIM" "$RESET"
# SCENE: given a settings file whose "permissions.deny" is a string, not a list;
# when init runs; expect the refusal BEFORE the first byte — a parse that fires
# in step 4 has already rewritten AGENTS.md and CLAUDE.md by the time it speaks.
B="$TMP/badsettings"; mkrepo "$B"; mkdir -p "$B/.claude"
printf '{ "permissions": { "deny": "Edit(x)" } }\n' > "$B/.claude/settings.json"
printf '# Agents\n' > "$B/AGENTS.md"; printf '# Claude\n' > "$B/CLAUDE.md"
BA=$(sha "$B/AGENTS.md"); BC=$(sha "$B/CLAUDE.md")
RC=$(run "$B")
[[ "$RC" == "1" ]] && ok "a settings file whose deny is not a list exits 1" || fail "badsettings exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'is not a list' && ok "the refusal names the shape it found" || fail "badsettings reason" "$(cat "$OUT")"
[[ "$BA" == "$(sha "$B/AGENTS.md")" && "$BC" == "$(sha "$B/CLAUDE.md")" ]] \
  && ok "AGENTS.md and CLAUDE.md are byte-identical after the refusal" || fail "badsettings mutated" "one of them changed"
[[ ! -f "$B/docs/llm-orchestrator/LAWS.md" && ! -f "$B/docs/llm-orchestrator/cadence.json" ]] \
  && ok "the settings refusal writes no law document and no cadence.json" || fail "badsettings partial" "$(ls -R "$B" | tr '\n' ' ')"
has "$OUT" 'nothing was written' && ok "and the report says nothing was written" || fail "badsettings silence" "$(cat "$OUT")"

# SCENE: given an AGENTS.md carrying <!-- ORCH:LAWS:START --> with no matching
# END; when init runs; expect a refusal in the preflight — today the malformed
# section is only caught by the lock, after the whole project has been written.
M="$TMP/marker"; mkrepo "$M"
printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nhalf a block\n' > "$M/AGENTS.md"
BEFORE=$(sha "$M/AGENTS.md")
RC=$(run "$M")
[[ "$RC" == "1" ]] && ok "a START with no END exits 1" || fail "marker exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'no matching' && ok "the refusal names the missing end marker" || fail "marker reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$M/AGENTS.md")" ]] && ok "the marker refusal leaves AGENTS.md alone" || fail "marker mutated" "changed"
[[ ! -f "$M/docs/llm-orchestrator/cadence.json" && ! -f "$M/docs/llm-orchestrator/LAWS.md" ]] \
  && ok "the marker refusal writes nothing else either" || fail "marker partial" "$(ls -R "$M" | tr '\n' ' ')"

printf '\n%s== a write that cannot succeed is refused, never reported as done ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose .claude/ cannot be written to; when init runs;
# expect a refusal and a non-zero exit — not `created .claude/settings.json`
# followed by `lock OK` over a settings file that is not there.
W="$TMP/unwritable"; mkrepo "$W"; mkdir -p "$W/.claude"; chmod 500 "$W/.claude"
RC=$(run "$W")
[[ "$RC" == "1" ]] && ok "an unwritable .claude/ exits 1" || fail "unwritable exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'refused' && ok "it says refused and names the path" || fail "unwritable reason" "$(cat "$OUT")"
has "$OUT" 'lock OK' && fail "unwritable verdict" "the report claimed lock OK over a settings file it never wrote" || ok "no lock OK is printed over a failed write"
has "$OUT" 'created .claude/settings.json' && fail "unwritable created" "created was printed for a write that failed" || ok "no created line for a write that could not succeed"
[[ ! -f "$W/.claude/settings.json" && ! -f "$W/docs/llm-orchestrator/LAWS.md" ]] \
  && ok "the unwritable project keeps every byte it had" || fail "unwritable partial" "$(ls -R "$W" 2>/dev/null | tr '\n' ' ')"
chmod 700 "$W/.claude"

printf '\n%s== the report closes with the arming recipe, in order ==%s\n' "$DIM" "$RESET"
# SCENE: given a fresh init; when the report ends; expect the four steps that
# take the project from written to armed, in the order they must be run — a
# reader who commits before re-locking walks into a refusal.
R4="$TMP/recipe"; mkrepo "$R4"
RC=$(run "$R4")
S1=$(lineof "$OUT" '1. fill in every <PLACEHOLDER>')
S2=$(lineof "$OUT" '2. re-lock')
S3=$(lineof "$OUT" '3. route this clone')
S4=$(lineof "$OUT" '4. commit what was written')
if [[ -n "$S1" && -n "$S2" && -n "$S3" && -n "$S4" ]]; then ok "the report carries all four arming steps"; else fail "recipe steps" "1=$S1 2=$S2 3=$S3 4=$S4 out=$(cat "$OUT")"; fi
if [[ -n "$S1" && -n "$S2" && -n "$S3" && -n "$S4" ]] && (( S1 < S2 && S2 < S3 && S3 < S4 )); then ok "the four steps print in the order they must be run"; else fail "recipe order" "1=$S1 2=$S2 3=$S3 4=$S4"; fi
has "$OUT" '--lock' && ok "step 2 names the re-lock the placeholder fill makes necessary" || fail "recipe relock" "$(cat "$OUT")"
# The arming recipe ends where the alarm's last layer lives. The hook only fires
# in a clone whose hooks are routed; --audit is what holds when the hook was
# never installed or was stepped past, so the recipe names it as a step rather
# than leaving it in the docs for a reader who has already stopped reading.
S5=$(lineof "$OUT" '5. in CI, run .githooks/orch-cadence-check.sh --audit')
if [[ -n "$S5" ]]; then ok "the recipe carries the CI audit step"; else fail "recipe ci" "$(cat "$OUT")"; fi
if [[ -n "$S4" && -n "$S5" ]] && (( S4 < S5 )); then ok "and prints it after the commit it audits"; else fail "recipe ci order" "4=$S4 5=$S5"; fi
has "$OUT" 'in CI, run .githooks/orch-cadence-check.sh --audit HEAD (see docs/install.md, "The lock'"'"'s two layers")' \
  && ok "and the step names the command and the heading that explains it" || fail "recipe ci text" "$(cat "$OUT")"

printf '\n%s== @AGENTS.md counts only as line 1, exactly ==%s\n' "$DIM" "$RESET"
# SCENE: given a CLAUDE.md whose first line is @AGENTSXmd (the dot is a regex
# wildcard, not a character); when init runs; expect the import inserted.
X="$TMP/import-x"; mkrepo "$X"
printf '@AGENTSXmd\n\nbody\n' > "$X/CLAUDE.md"
RC=$(run "$X")
[[ "$(head -1 "$X/CLAUDE.md")" == "@AGENTS.md" ]] && ok "a near-miss line does not count as the import" || fail "regex import" "head -1 is $(head -1 "$X/CLAUDE.md")"
# SCENE: given a CLAUDE.md whose only @AGENTS.md sits inside a code fence; when
# init runs; expect the import inserted at line 1 — sample text governs nothing.
Y="$TMP/import-fence"; mkrepo "$Y"
printf '# CLAUDE.md\n\n```\n@AGENTS.md\n```\n' > "$Y/CLAUDE.md"
RC=$(run "$Y")
[[ "$(head -1 "$Y/CLAUDE.md")" == "@AGENTS.md" ]] && ok "a fenced @AGENTS.md does not count as the import" || fail "fenced import" "head -1 is $(head -1 "$Y/CLAUDE.md")"

printf '\n%s== a link that leaves the project is refused ==%s\n' "$DIM" "$RESET"
# SCENE: given CLAUDE.md as a symlink to a file outside the project root; when
# init runs; expect a refusal and the outside file untouched — an init must not
# edit a file the person did not point this run at.
L="$TMP/link"; mkrepo "$L"; mkdir -p "$TMP/outside"
printf '# somebody else\n' > "$TMP/outside/CLAUDE.md"
ln -s "$TMP/outside/CLAUDE.md" "$L/CLAUDE.md"
OSHA=$(sha "$TMP/outside/CLAUDE.md")
RC=$(run "$L")
[[ "$RC" == "1" ]] && ok "a link out of the project exits 1" || fail "link exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'leaves the project' && ok "the refusal says the link leaves the project" || fail "link reason" "$(cat "$OUT")"
[[ "$OSHA" == "$(sha "$TMP/outside/CLAUDE.md")" ]] && ok "the file outside the project is byte-identical" || fail "outside written" "the init wrote through the link"
[[ ! -f "$L/docs/llm-orchestrator/LAWS.md" ]] && ok "and the link refusal writes nothing inside the project" || fail "link partial" "LAWS.md written"
# SCENE: given CLAUDE.md linked to AGENTS.md inside the root; when init runs;
# expect a refusal — one file cannot import itself.
L2="$TMP/selflink"; mkrepo "$L2"
printf '# Agents\n' > "$L2/AGENTS.md"
( cd "$L2" && ln -s AGENTS.md CLAUDE.md )
RC=$(run "$L2")
[[ "$RC" == "1" ]] && ok "CLAUDE.md and AGENTS.md as one file exits 1" || fail "selflink exit" "rc=$RC out=$(cat "$OUT")"
[[ "$(head -1 "$L2/AGENTS.md")" != "@AGENTS.md" ]] && ok "no file is made to import itself" || fail "self import" "AGENTS.md now opens with @AGENTS.md"

printf '\n%s== --root must name a directory that exists ==%s\n' "$DIM" "$RESET"
# SCENE: given --root pointing at a path that does not exist; when init runs;
# expect a refusal — a typo in a root should not scaffold a new project tree.
RC=$(run "$TMP/nope/deep")
[[ "$RC" == "1" ]] && ok "--root on a missing directory exits 1" || fail "root exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'no such directory' && ok "the refusal names the missing directory" || fail "root reason" "$(cat "$OUT")"
[[ ! -d "$TMP/nope" ]] && ok "and the directory is not created" || fail "root created" "$TMP/nope exists"

printf '\n%s== a second run reports the lock as kept, not refused ==%s\n' "$DIM" "$RESET"
# SCENE: given an initialized project; when init runs again without the unlock;
# expect the expected no-op said as a no-op — a REFUSED line in a run that
# exits 0 teaches the reader to read refusals as noise.
RC=$(run "$F")
[[ "$RC" == "0" ]] && ok "the no-op re-run exits 0" || fail "noop exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'lock kept (already armed' && ok "the report says the lock is kept, already armed" || fail "noop lock line" "$(cat "$OUT")"
has "$OUT" 'REFUSED' && fail "noop refused" "a run that exits 0 printed REFUSED: $(grep -F 'REFUSED' "$OUT")" || ok "no REFUSED line in a run that exits 0"

printf '\n%s== the settings backup is not committed by the arming commit ==%s\n' "$DIM" "$RESET"
# SCENE: given a project with its own settings file and a .gitignore; when init
# runs; expect the backup of the operator's settings ignored — `git add -A` in
# the arming commit would otherwise track it.
GI="$TMP/gitignore"; mkrepo "$GI"; mkdir -p "$GI/.claude"
printf '{ "model": "opus" }\n' > "$GI/.claude/settings.json"
printf 'node_modules/\n' > "$GI/.gitignore"
RC=$(run "$GI")
[[ "$RC" == "0" ]] && ok "the gitignore fixture initializes" || fail "gitignore exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'appended .gitignore' && ok "the report says appended .gitignore" || fail "gitignore line" "$(cat "$OUT")"
has "$GI/.gitignore" '.claude/settings.json.bak' && ok ".gitignore carries the settings backup" || fail "gitignore rule" "$(cat "$GI/.gitignore")"
has "$GI/.gitignore" 'node_modules/' && ok "the project's own .gitignore entries survive" || fail "gitignore clobbered" "$(cat "$GI/.gitignore")"
[[ -f "$GI/.claude/settings.json.bak" ]] && ok "the backup exists (so the rule is not decoration)" || fail "gitignore no bak" "no .bak was made"
( cd "$GI" && git add -A ) >/dev/null 2>&1
TRACKED=$( cd "$GI" && git ls-files | grep -c '\.bak' )
[[ "$TRACKED" == "0" ]] && ok "the arming commit's tree has no .bak in it" || fail "bak tracked" "$( cd "$GI" && git ls-files | grep '\.bak' | tr '\n' ' ')"

printf '\n%s== a root that is not a git repository gets no git layer ==%s\n' "$DIM" "$RESET"
# SCENE: given a project directory that is not a git working tree; when init
# runs; expect the documents written and the git layer skipped out loud — hooks
# in a directory git never reads are enforcement that does not exist.
NG="$TMP/nogit"; mkproj "$NG"
RC=$(run "$NG")
[[ "$RC" == "0" ]] && ok "a non-git root exits 0" || fail "nogit exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'git layer skipped: not a git repository' && ok "the report says the git layer was skipped and why" || fail "nogit line" "$(cat "$OUT")"
[[ ! -f "$NG/.githooks/commit-msg" ]] && ok "no hook is written where git will never run one" || fail "nogit hooks" "$(ls "$NG/.githooks" 2>/dev/null | tr '\n' ' ')"
has "$OUT" 'core.hooksPath' && fail "nogit hookspath" "the hooks-path line was printed for a directory with no repository" || ok "and the hooks-path one-liner is not printed"
[[ -f "$NG/docs/llm-orchestrator/LAWS.md" ]] && ok "the law documents are still written" || fail "nogit docs" "LAWS.md missing"

printf '\n%s== --adopt still names the placeholders in a template it wrote ==%s\n' "$DIM" "$RESET"
# SCENE: given --adopt on a project that has no LAWS.md of its own; when init
# runs; expect the reminder — the flag suppresses it for laws that were KEPT,
# and a placeholder template nobody is told to fill is a law file of blanks.
AD2="$TMP/adopt2"; mkrepo "$AD2"
RC=$(run "$AD2" --adopt)
[[ "$RC" == "0" ]] && ok "--adopt on a project with no laws exits 0" || fail "adopt2 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'created docs/llm-orchestrator/LAWS.md' && ok "--adopt writes the template when the project has none" || fail "adopt2 create" "$(cat "$OUT")"
has "$OUT" '<PLACEHOLDER>' && ok "and the reminder still names the placeholders it just wrote" || fail "adopt2 reminder" "$(cat "$OUT")"

printf '\n%s== a tilde fence counts as a fence ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md ending inside an unclosed ~~~ fence; when init runs;
# expect the same refusal the backtick fence gets — the block would be buried
# either way.
T3="$TMP/tilde"; mkrepo "$T3"
printf '# Agents\n\n~~~bash\necho "someone forgot to close this"\n' > "$T3/AGENTS.md"
BEFORE=$(sha "$T3/AGENTS.md")
RC=$(run "$T3")
[[ "$RC" == "1" ]] && ok "an unclosed ~~~ fence exits 1" || fail "tilde exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused AGENTS.md' && ok "the tilde refusal names AGENTS.md" || fail "tilde reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$T3/AGENTS.md")" ]] && ok "the tilde refusal leaves AGENTS.md alone" || fail "tilde mutated" "changed"
[[ ! -f "$T3/docs/llm-orchestrator/LAWS.md" ]] && ok "and writes nothing else" || fail "tilde partial" "LAWS.md written"

printf '\n%s== every path the report prints can be pasted ==%s\n' "$DIM" "$RESET"
# SCENE: given a project root whose path contains a space; when init runs with
# --dry-run; expect the command it names to be quoted — an unquoted path is a
# line that cannot be run.
SP="$TMP/space dir/g"; mkrepo "$SP"
RC=$(run "$SP" --dry-run)
[[ "$RC" == "0" ]] && ok "--dry-run under a root with a space exits 0" || fail "space exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" "--root \"$SP\"" && ok "the dry-run names the root quoted" || fail "space quoting" "$(grep -F 'would run' "$OUT")"

printf '\n%s== the command file names the mechanism a re-run actually meets ==%s\n' "$DIM" "$RESET"
# SCENE: given the command file's constraint about re-running; when a reader
# follows it; expect what a re-run actually meets — a no-op only while the
# section still matches the block, a refusal once it has drifted — plus both
# true reasons: the script keeps existing files, and the lock guard refuses the
# config paths. "A no-op unless the unlock is set" was true before the content
# rule and is not true now: a drifted section exits 1.
CMDF="$ROOT/commands/cadence-init.md"
has "$CMDF" 'is a no-op while its' \
  && ok "the command file calls a re-run a no-op only conditionally" || fail "cmd noop" "$(sed -n '105,125p' "$CMDF")"
has "$CMDF" '`ORCH:LAWS` section still matches the current block,' \
  && ok "and names the condition: the section still matches the block" || fail "cmd match" "$(sed -n '105,125p' "$CMDF")"
has "$CMDF" 'and a refusal once that section has drifted;' \
  && ok "and calls a drifted section a refusal, which is what it is" || fail "cmd drift" "$(sed -n '105,125p' "$CMDF")"
has "$CMDF" 'is a no-op unless' && fail "cmd stale" "the pre-content-rule sentence is still in the command file" \
  || ok "and the pre-content-rule sentence is gone"
has "$CMDF" 'the script itself keeps every file' && ok "and names the script's own keeping as one reason" || fail "cmd keep" "$(sed -n '105,120p' "$CMDF")"
has "$CMDF" 'the lock guard refuses edits to the config paths' && ok "and the lock guard as the other" || fail "cmd guard" "$(sed -n '105,120p' "$CMDF")"
has "$CMDF" 'orch-cadence-check.sh --audit' \
  && ok "and the command file names the CI audit step the script prints" || fail "cmd ci" "$(sed -n '95,120p' "$CMDF")"

printf '\n%s== the report carries exactly one sandbox tip ==%s\n' "$DIM" "$RESET"
# SCENE: given any run of init; when the report ends; expect one line telling
# the reader the deny rules bind subprocesses when the sandbox is on — printed,
# never written into the project.
TP="$TMP/tip"; mkrepo "$TP"
RC=$(run "$TP")
N=$(grep -cF "sandbox is optional" "$OUT")
[[ "$N" == "1" ]] && ok "the real run prints exactly one tip line" || fail "tip count" "count=$N out=$(cat "$OUT")"
has "$OUT" 'deny rules above also bind every subprocess' && ok "the tip says what the sandbox changes" || fail "tip text" "$(grep -F 'tip:' "$OUT")"
# The pin is the tip line's EXACT text. A tip that says the sandbox exists but
# not how to reach it leaves the reader with a layer they cannot turn on, and a
# settings key spelled from memory sends them to a knob Claude Code ignores —
# so both spellings are pinned literally: the in-session command and the
# settings.json key, verified against the Claude Code settings reference.
TIP_EXACT='tip: Claude Code'"'"'s sandbox is optional; turn it on with /sandbox in a session or "sandbox": {"enabled": true} in .claude/settings.json, and the Edit(...) deny rules above also bind every subprocess (see docs/install.md, "The lock'"'"'s two layers")'
has "$OUT" "$TIP_EXACT" && ok "the tip line reads exactly as pinned" || fail "tip exact" "$(grep -F 'tip:' "$OUT")"
has "$OUT" '/sandbox in a session' && ok "and names the in-session command that turns it on" || fail "tip cmd" "$(grep -F 'tip:' "$OUT")"
has "$OUT" '"sandbox": {"enabled": true} in .claude/settings.json' && ok "and the settings key, spelled as the reference spells it" || fail "tip key" "$(grep -F 'tip:' "$OUT")"
has "$OUT" 'docs/install.md, "The lock'"'"'s two layers"' && ok "and points at the heading that explains both layers" || fail "tip heading" "$(grep -F 'tip:' "$OUT")"
TP2="$TMP/tip2"; mkrepo "$TP2"
RC=$(run "$TP2" --dry-run)
[[ "$(grep -cF "sandbox is optional" "$OUT")" == "1" ]] && ok "--dry-run prints it too" || fail "tip dry" "$(cat "$OUT")"
bash "$INIT" --help > "$OUT" 2>&1
has "$OUT" 'sandbox is optional' && fail "tip in help" "--help printed the tip" || ok "--help does not print it"
if grep -rlF "sandbox is optional" "$TP" >/dev/null 2>&1; then fail "tip written" "$(grep -rlF 'sandbox is optional' "$TP" | tr '\n' ' ')"; else ok "and no file in the project carries it"; fi

printf '\n%s== containment covers every component of a path, not only its leaf ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose docs/ is a symlink to a directory outside the
# project root; when init runs; expect the refusal a symlinked CLAUDE.md already
# gets, with nothing written — not four law documents in somebody else's folder.
CD1="$TMP/comp-docs"; mkrepo "$CD1"; mkdir -p "$TMP/comp-out1"
printf 'not ours\n' > "$TMP/comp-out1/keep.txt"
ln -s "$TMP/comp-out1" "$CD1/docs"
O1=$(tree_sha "$TMP/comp-out1")
RC=$(run "$CD1")
[[ "$RC" == "1" ]] && ok "a docs/ that links out of the project exits 1" || fail "comp docs exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'leaves the project' && ok "the docs refusal says the link leaves the project" || fail "comp docs reason" "$(cat "$OUT")"
[[ "$O1" == "$(tree_sha "$TMP/comp-out1")" ]] && ok "the directory outside the project is byte-identical" || fail "comp docs outside" "the init wrote through the link"
[[ ! -f "$CD1/AGENTS.md" && ! -f "$CD1/CLAUDE.md" && ! -f "$CD1/.claude/settings.json" ]] \
  && ok "and the docs refusal writes nothing inside the project either" || fail "comp docs partial" "$(ls -R "$CD1" | tr '\n' ' ')"

# SCENE: given a project whose .claude/ is a symlink to a directory outside the
# root; when init runs; expect a refusal — the deny rules are the primary lock
# layer, and writing them outside leaves the project itself with none.
CD2="$TMP/comp-claude"; mkrepo "$CD2"; mkdir -p "$TMP/comp-out2"
printf 'not ours\n' > "$TMP/comp-out2/keep.txt"
ln -s "$TMP/comp-out2" "$CD2/.claude"
O2=$(tree_sha "$TMP/comp-out2")
RC=$(run "$CD2")
[[ "$RC" == "1" ]] && ok "a .claude/ that links out of the project exits 1" || fail "comp claude exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'leaves the project' && ok "the .claude refusal says the link leaves the project" || fail "comp claude reason" "$(cat "$OUT")"
[[ "$O2" == "$(tree_sha "$TMP/comp-out2")" ]] && ok "no settings file is written outside the root" || fail "comp claude outside" "the init wrote through the link"
[[ ! -f "$CD2/docs/llm-orchestrator/LAWS.md" ]] && ok "and the .claude refusal writes no law document" || fail "comp claude partial" "$(ls -R "$CD2" | tr '\n' ' ')"

# SCENE: given a project whose .githooks/ is a symlink to a directory outside
# the root; when init runs; expect a refusal — a hook copied outside the project
# is enforcement the project's own clone will never run.
CD3="$TMP/comp-hooks"; mkrepo "$CD3"; mkdir -p "$TMP/comp-out3"
printf 'not ours\n' > "$TMP/comp-out3/keep.txt"
ln -s "$TMP/comp-out3" "$CD3/.githooks"
O3=$(tree_sha "$TMP/comp-out3")
RC=$(run "$CD3")
[[ "$RC" == "1" ]] && ok "a .githooks/ that links out of the project exits 1" || fail "comp hooks exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'leaves the project' && ok "the .githooks refusal says the link leaves the project" || fail "comp hooks reason" "$(cat "$OUT")"
[[ "$O3" == "$(tree_sha "$TMP/comp-out3")" ]] && ok "no hook is written outside the root" || fail "comp hooks outside" "the init wrote through the link"
[[ ! -f "$CD3/docs/llm-orchestrator/LAWS.md" ]] && ok "and the .githooks refusal writes no law document" || fail "comp hooks partial" "$(ls -R "$CD3" | tr '\n' ' ')"

# SCENE: given a project whose docs/ is a symlink to a directory INSIDE the root;
# when init runs; expect it followed, not refused — the write lands where the
# person pointed it, and it is still inside the project.
CD4="$TMP/comp-intree"; mkrepo "$CD4"; mkdir -p "$CD4/documentation"
( cd "$CD4" && ln -s documentation docs )
RC=$(run "$CD4")
[[ "$RC" == "0" ]] && ok "an in-tree docs link is followed, not refused" || fail "comp intree exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
[[ -f "$CD4/documentation/llm-orchestrator/LAWS.md" ]] && ok "and the law documents land inside the root" || fail "comp intree landing" "$(ls -R "$CD4" | tr '\n' ' ')"

printf '\n%s== a second ORCH:LAWS pair is refused before anything is written ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md carrying two complete ORCH:LAWS marker pairs; when
# init runs; expect a preflight refusal naming the duplicate marker — the lock
# refuses it either way, but the lock speaks after the whole project is written.
D1="$TMP/dupmark"; mkrepo "$D1"
{ printf '# Agents\n\n'
  printf '<!-- ORCH:LAWS:START -->\nfirst\n<!-- ORCH:LAWS:END -->\n\n'
  printf '<!-- ORCH:LAWS:START -->\nsecond\n<!-- ORCH:LAWS:END -->\n'; } > "$D1/AGENTS.md"
BEFORE=$(sha "$D1/AGENTS.md")
RC=$(run "$D1")
[[ "$RC" == "1" ]] && ok "two ORCH:LAWS pairs in AGENTS.md exit 1" || fail "dup exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'duplicate marker' && ok "the refusal names the duplicate marker" || fail "dup reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$D1/AGENTS.md")" ]] && ok "AGENTS.md is byte-identical after the duplicate refusal" || fail "dup mutated" "changed"
[[ ! -f "$D1/docs/llm-orchestrator/cadence.json" && ! -f "$D1/docs/llm-orchestrator/LAWS.md" && ! -f "$D1/.claude/settings.json" ]] \
  && ok "no cadence.json, no law document, no settings file" || fail "dup partial" "$(ls -R "$D1" | tr '\n' ' ')"
has "$OUT" 'nothing was written' && ok "and the duplicate refusal says nothing was written" || fail "dup silence" "$(cat "$OUT")"

# SCENE: given a CLAUDE.md carrying two complete ORCH:LAWS pairs; when init runs;
# expect the same refusal — the manifest hashes that file's section too.
D2="$TMP/dupmark-claude"; mkrepo "$D2"
{ printf '# Claude\n\n'
  printf '<!-- ORCH:LAWS:START -->\nfirst\n<!-- ORCH:LAWS:END -->\n\n'
  printf '<!-- ORCH:LAWS:START -->\nsecond\n<!-- ORCH:LAWS:END -->\n'; } > "$D2/CLAUDE.md"
BEFORE=$(sha "$D2/CLAUDE.md")
RC=$(run "$D2")
[[ "$RC" == "1" ]] && ok "two ORCH:LAWS pairs in CLAUDE.md exit 1" || fail "dup2 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'duplicate marker' && ok "that refusal names the duplicate marker too" || fail "dup2 reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$D2/CLAUDE.md")" ]] && ok "CLAUDE.md is byte-identical after it" || fail "dup2 mutated" "changed"
[[ ! -f "$D2/docs/llm-orchestrator/cadence.json" && ! -f "$D2/docs/llm-orchestrator/LAWS.md" ]] \
  && ok "and it writes no cadence.json and no law document" || fail "dup2 partial" "$(ls -R "$D2" | tr '\n' ' ')"

printf '\n%s== a directory sitting at a target path is refused in the preflight ==%s\n' "$DIM" "$RESET"
# SCENE: given a directory at .claude/settings.json; when init runs; expect a
# refusal before the first byte — not six files written and then a settings
# write that cannot succeed.
DS="$TMP/dirsettings"; mkrepo "$DS"; mkdir -p "$DS/.claude/settings.json"
RC=$(run "$DS")
[[ "$RC" == "1" ]] && ok "a directory at .claude/settings.json exits 1" || fail "dirset exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused .claude/settings.json' && ok "the refusal names the path the directory sits at" || fail "dirset reason" "$(cat "$OUT")"
[[ ! -f "$DS/docs/llm-orchestrator/LAWS.md" && ! -f "$DS/AGENTS.md" && ! -f "$DS/CLAUDE.md" ]] \
  && ok "nothing is written ahead of it" || fail "dirset partial" "$(ls -R "$DS" | tr '\n' ' ')"
has "$OUT" 'nothing was written' && ok "and the directory refusal says nothing was written" || fail "dirset silence" "$(cat "$OUT")"

printf '\n%s== a settings write that cannot land is refused, never reported done ==%s\n' "$DIM" "$RESET"
# SCENE: given .claude/settings.json as an in-tree link to a path in a directory
# that cannot be written to; when init runs; expect the write guard to speak —
# `created` for a file that is not there is the report lying about the project.
UW="$TMP/rolink"; mkrepo "$UW"; mkdir -p "$UW/.claude" "$UW/ro"
( cd "$UW" && ln -s ../ro/settings.json .claude/settings.json )
chmod 500 "$UW/ro"
RC=$(run "$UW")
[[ "$RC" == "1" ]] && ok "a settings write that cannot land exits 1" || fail "rolink exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'refused .claude/settings.json' && ok "the refusal names the settings file" || fail "rolink reason" "$(cat "$OUT")"
has "$OUT" 'created .claude/settings.json' && fail "rolink created" "created was printed for a write that failed" || ok "no created line for the settings write that failed"
has "$OUT" 'lock OK' && fail "rolink verdict" "the report claimed lock OK over a settings file it never wrote" || ok "no lock OK over a settings file that was never written"
[[ ! -f "$UW/docs/llm-orchestrator/LOCK.sha256" ]] && ok "and no manifest is armed over it" || fail "rolink lock" "LOCK.sha256 written"
chmod 700 "$UW/ro"

printf '\n%s== a marker pair inside a code fence is never the live section ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md whose only ORCH:LAWS marker pair sits inside a
# closed code fence; when init runs; expect a refusal naming the fenced markers
# with nothing written — the lock takes the FIRST pair it meets, fenced or not,
# so `kept` here arms a project whose agent-facing law block does not exist and
# whose manifest hashes sample text.
FP1="$TMP/fencedpair"; mkrepo "$FP1"
{ printf '# Agents\n\nWhat the cadence would add:\n\n'
  printf '```\n<!-- ORCH:LAWS:START -->\nsample laws\n<!-- ORCH:LAWS:END -->\n```\n\nTail.\n'; } > "$FP1/AGENTS.md"
BEFORE=$(sha "$FP1/AGENTS.md")
RC=$(run "$FP1")
[[ "$RC" == "1" ]] && ok "a fenced ORCH:LAWS pair in AGENTS.md exits 1" || fail "fpair exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused AGENTS.md' && ok "the refusal names AGENTS.md" || fail "fpair reason" "$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "and says that section is not the current cadence block" || fail "fpair wording" "$(cat "$OUT")"
has "$OUT" "compared against $BLOCK" && ok "and names the block file it compared against" || fail "fpair source" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$FP1/AGENTS.md")" ]] && ok "AGENTS.md is byte-identical after the fenced-pair refusal" || fail "fpair mutated" "changed"
[[ ! -f "$FP1/docs/llm-orchestrator/LAWS.md" && ! -f "$FP1/docs/llm-orchestrator/cadence.json" && ! -f "$FP1/.claude/settings.json" ]] \
  && ok "no law document, no cadence.json and no settings file behind it" || fail "fpair partial" "$(ls -R "$FP1" | tr '\n' ' ')"
has "$OUT" 'nothing was written' && ok "and the fenced-pair refusal says nothing was written" || fail "fpair silence" "$(cat "$OUT")"

# SCENE: the same file shape in CLAUDE.md — the manifest hashes that file's
# section too, so a fenced sample there is the same hole.
FP2="$TMP/fencedpair-claude"; mkrepo "$FP2"
{ printf '@AGENTS.md\n\n# Claude\n\nWhat the cadence would add:\n\n'
  printf '```\n<!-- ORCH:LAWS:START -->\nsample laws\n<!-- ORCH:LAWS:END -->\n```\n'; } > "$FP2/CLAUDE.md"
BEFORE=$(sha "$FP2/CLAUDE.md")
RC=$(run "$FP2")
[[ "$RC" == "1" ]] && ok "a fenced ORCH:LAWS pair in CLAUDE.md exits 1" || fail "fpair2 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused CLAUDE.md' && ok "that refusal names CLAUDE.md" || fail "fpair2 reason" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$FP2/CLAUDE.md")" ]] && ok "CLAUDE.md is byte-identical after it" || fail "fpair2 mutated" "changed"
[[ ! -f "$FP2/docs/llm-orchestrator/cadence.json" && ! -f "$FP2/docs/llm-orchestrator/LAWS.md" ]] \
  && ok "and it writes no cadence.json and no law document" || fail "fpair2 partial" "$(ls -R "$FP2" | tr '\n' ' ')"

# SCENE: a live pair outside every fence PLUS a fenced sample below it. The lock
# hashes the first pair it meets and then refuses the file for the second start
# marker; the reason has to say which pair it would read.
FP3="$TMP/livepair-plus-fenced"; mkrepo "$FP3"
{ printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n\nFor reference, the shape:\n\n'
  printf '```\n<!-- ORCH:LAWS:START -->\nsample\n<!-- ORCH:LAWS:END -->\n```\n'; } > "$FP3/AGENTS.md"
BEFORE=$(sha "$FP3/AGENTS.md")
RC=$(run "$FP3")
[[ "$RC" == "1" ]] && ok "a live pair plus a fenced sample exits 1" || fail "fpair3 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'duplicate marker' && ok "the refusal names the duplicate marker — a sample beside a live block is a second START" || fail "fpair3 wording" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$FP3/AGENTS.md")" ]] && ok "AGENTS.md is byte-identical after that refusal" || fail "fpair3 mutated" "changed"
has "$OUT" 'nothing was written' && ok "and it says nothing was written" || fail "fpair3 silence" "$(cat "$OUT")"

# SCENE: a live pair carrying the block itself and no fence anywhere — the case
# that must not change. The section is built by cat-ing the resolved block: a
# hand-typed copy is exactly what the content test refuses.
FP4="$TMP/livepair-plain"; mkrepo "$FP4"
{ printf '# Agents\n\n'; cat "$BLOCK"; } > "$FP4/AGENTS.md"
BEFORE=$(sha "$FP4/AGENTS.md")
RC=$(run "$FP4")
[[ "$RC" == "0" ]] && ok "a live pair with no fence still initializes at exit 0" || fail "fpair4 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && ok "and the report still says kept for it" || fail "fpair4 kept" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$FP4/AGENTS.md")" ]] && ok "and that AGENTS.md is untouched" || fail "fpair4 mutated" "changed"

# SCENE: a fenced sample of ONLY the start marker — the existing unterminated
# verdict owns that file, and the fence rule must not take it over.
FP5="$TMP/fenced-start-only"; mkrepo "$FP5"
{ printf '# Agents\n\nThe block opens with:\n\n'
  printf '```\n<!-- ORCH:LAWS:START -->\n```\n\nTail.\n'; } > "$FP5/AGENTS.md"
RC=$(run "$FP5")
[[ "$RC" == "1" ]] && ok "a fenced lone start marker exits 1" || fail "fpair5 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'unterminated section' && ok "with the unterminated verdict — markers are counted, code contexts are not read" || fail "fpair5 verdict" "$(cat "$OUT")"

printf '\n%s== a marked section that is not the block refuses: the four shapes that armed a project over prose ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md whose only ORCH:LAWS START marker sits inside a
# closed code fence and whose only END marker is quoted live in prose below it;
# when cadence-init.sh --root <project> runs; expect a refusal naming the fenced
# marker — not `kept AGENTS.md` followed by `lock OK` over a file that has no
# live section, never receives one, and whose manifest hashes a fence line and a
# sentence of prose. The lock ACCEPTS this file; the init is deliberately
# stricter, and that divergence is asserted, not assumed.
CX1="$TMP/ctx-fenced-start"; mkrepo "$CX1"
{ printf '# Agents\n\nThe cadence block opens with a marker on a line of its own:\n\n'
  printf '```\n<!-- ORCH:LAWS:START -->\n```\n\n'
  printf 'The section closes with <!-- ORCH:LAWS:END --> on a line of its own.\n'; } > "$CX1/AGENTS.md"
BEFORE=$(sha "$CX1/AGENTS.md")
RC=$(run "$CX1")
[[ "$RC" == "1" ]] && ok "a fenced START with a live END exits 1" || fail "ctx1 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused AGENTS.md' && ok "the refusal names AGENTS.md" || fail "ctx1 reason" "$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "and says the marked section is not the current cadence block" || fail "ctx1 wording" "$(cat "$OUT")"
has "$OUT" '(lines 6–9)' && ok "and names the two lines the span runs between" || fail "ctx1 which" "$(cat "$OUT")"
has "$OUT" 'ORCH_CADENCE_UNLOCK=1' && ok "and orders the two remedies with the unlock first" || fail "ctx1 remedy" "$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && fail "ctx1 kept" "kept was printed over a file with no live section" || ok "and it never prints kept over that file"
[[ "$BEFORE" == "$(sha "$CX1/AGENTS.md")" ]] && ok "AGENTS.md is byte-identical after it" || fail "ctx1 mutated" "changed"
[[ ! -f "$CX1/docs/llm-orchestrator/LAWS.md" && ! -f "$CX1/docs/llm-orchestrator/cadence.json" && ! -f "$CX1/docs/llm-orchestrator/LOCK.sha256" ]] \
  && ok "no law document, no cadence.json and no manifest behind it" || fail "ctx1 partial" "$(ls -R "$CX1" | tr '\n' ' ')"
has "$OUT" 'nothing was written' && ok "and it says nothing was written" || fail "ctx1 silence" "$(cat "$OUT")"
lock_probe "$CX1/AGENTS.md"; LRC="$LOCK_RC"
[[ "$LRC" == "0" && "$LOCK_SECT_SHA" == "$(sect_sha "$CX1/AGENTS.md")" ]] \
  && ok "recorded divergence: the init refuses this file; --lock accepts it and hashes the fenced marker as the section" \
  || fail "ctx1 lock" "rc=$LRC sha=$LOCK_SECT_SHA $(cat "$TMP/lockprobe.log")"

# SCENE: the mirror — a live START in prose with the END inside a fence below.
CX2="$TMP/ctx-fenced-end"; mkrepo "$CX2"
{ printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n\nThe block closes with:\n\n'
  printf '```\n<!-- ORCH:LAWS:END -->\n```\n'; } > "$CX2/AGENTS.md"
BEFORE=$(sha "$CX2/AGENTS.md")
RC=$(run "$CX2")
[[ "$RC" == "1" ]] && ok "a live START with a fenced END exits 1" || fail "ctx2 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "the refusal says the marked section is not the current cadence block" || fail "ctx2 wording" "$(cat "$OUT")"
has "$OUT" '(lines 3–9)' && ok "and names the span it read, not a code context" || fail "ctx2 which" "$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && fail "ctx2 kept" "kept was printed over a file with no live section" || ok "and never prints kept over it"
[[ "$BEFORE" == "$(sha "$CX2/AGENTS.md")" ]] && ok "that AGENTS.md is byte-identical" || fail "ctx2 mutated" "changed"
[[ ! -f "$CX2/docs/llm-orchestrator/cadence.json" && ! -f "$CX2/docs/llm-orchestrator/LOCK.sha256" ]] \
  && ok "with no cadence.json and no manifest behind it" || fail "ctx2 partial" "$(ls -R "$CX2" | tr '\n' ' ')"
lock_probe "$CX2/AGENTS.md"; LRC="$LOCK_RC"
[[ "$LRC" == "0" && "$LOCK_SECT_SHA" == "$(sect_sha "$CX2/AGENTS.md")" ]] \
  && ok "recorded divergence: the init refuses the mirror; --lock accepts it" \
  || fail "ctx2 lock" "rc=$LRC sha=$LOCK_SECT_SHA $(cat "$TMP/lockprobe.log")"

# SCENE: a fence opened and never closed ABOVE a live-looking pair. The append
# path already refuses this file shape ("appending the block there would bury it
# inside the fence"); the preflight must agree instead of calling the pair live.
CX3="$TMP/ctx-unclosed"; mkrepo "$CX3"
{ printf '# Agents\n\nWhat the cadence adds:\n\n```\nsample\n\n'
  printf '<!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n'; } > "$CX3/AGENTS.md"
BEFORE=$(sha "$CX3/AGENTS.md")
RC=$(run "$CX3")
[[ "$RC" == "1" ]] && ok "a pair under a fence that is never closed exits 1" || fail "ctx3 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "the refusal says the marked section is not the current cadence block" || fail "ctx3 wording" "$(cat "$OUT")"
has "$OUT" '(lines 8–10)' && ok "and names the span, with no claim about a fence" || fail "ctx3 span" "$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && fail "ctx3 kept" "kept was printed over a pair buried in an unclosed fence" || ok "and never prints kept over it"
[[ "$BEFORE" == "$(sha "$CX3/AGENTS.md")" ]] && ok "that AGENTS.md is byte-identical" || fail "ctx3 mutated" "changed"
[[ ! -f "$CX3/docs/llm-orchestrator/cadence.json" && ! -f "$CX3/docs/llm-orchestrator/LOCK.sha256" ]] \
  && ok "with nothing written behind it" || fail "ctx3 partial" "$(ls -R "$CX3" | tr '\n' ' ')"
lock_probe "$CX3/AGENTS.md"; LRC="$LOCK_RC"
[[ "$LRC" == "0" && "$LOCK_SECT_SHA" == "$(sect_sha "$CX3/AGENTS.md")" ]] \
  && ok "recorded divergence: the init refuses the unclosed fence; --lock accepts it" \
  || fail "ctx3 lock" "rc=$LRC sha=$LOCK_SECT_SHA $(cat "$TMP/lockprobe.log")"

# SCENE: markdown's other code form — the pair written as a 4-space indented
# block. No fence line exists anywhere in the file.
CX4="$TMP/ctx-indented"; mkrepo "$CX4"
{ printf '# Agents\n\nFor reference, the shape the cadence adds:\n\n'
  printf '    <!-- ORCH:LAWS:START -->\n    the laws\n    <!-- ORCH:LAWS:END -->\n\nTail.\n'; } > "$CX4/AGENTS.md"
BEFORE=$(sha "$CX4/AGENTS.md")
RC=$(run "$CX4")
[[ "$RC" == "1" ]] && ok "a 4-space indented pair exits 1" || fail "ctx4 exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "the refusal says the marked section is not the current cadence block" || fail "ctx4 wording" "$(cat "$OUT")"
has "$OUT" '(lines 5–7)' && ok "and names the span — leading whitespace is content, so an indented block is not the block" || fail "ctx4 span" "$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && fail "ctx4 kept" "kept was printed over an indented sample" || ok "and never prints kept over it"
[[ "$BEFORE" == "$(sha "$CX4/AGENTS.md")" ]] && ok "that AGENTS.md is byte-identical" || fail "ctx4 mutated" "changed"
[[ ! -f "$CX4/docs/llm-orchestrator/cadence.json" && ! -f "$CX4/docs/llm-orchestrator/LOCK.sha256" ]] \
  && ok "with nothing written behind it" || fail "ctx4 partial" "$(ls -R "$CX4" | tr '\n' ' ')"
lock_probe "$CX4/AGENTS.md"; LRC="$LOCK_RC"
[[ "$LRC" == "0" && "$LOCK_SECT_SHA" == "$(sect_sha "$CX4/AGENTS.md")" ]] \
  && ok "recorded divergence: the init refuses the indented pair; --lock accepts it" \
  || fail "ctx4 lock" "rc=$LRC sha=$LOCK_SECT_SHA $(cat "$TMP/lockprobe.log")"

printf '\n%s== the conformance battery: every marker shape, through both readers ==%s\n' "$DIM" "$RESET"
# SCENE: given each shape a file's ORCH:LAWS markers can take; when init runs
# and when --lock runs over the same file; expect the ABSOLUTE verdict named
# here for the init, the measured verdict for the lock, and — as a SECOND
# assertion — that the two never diverge in the unsafe direction. Agreement is
# never the first assertion: the init and the lock AGREE on a fenced START with
# a live END (both used to accept it), which is the shape that reopened this.
# Where the init is deliberately stricter the divergence is asserted, so it is a
# recorded decision and not a silent one.
# Every fixture that expects `kept` builds its section by cat-ing the block the
# init resolved. A hand-typed copy is exactly what the content rule refuses, so
# a battery of hand-typed pairs would pin the wrong thing in both directions.
mkbat()  { local d="$TMP/bat-$1"; mkrepo "$d"; cat > "$d/AGENTS.md"; echo "$d"; }
mkbatc() { local d="$TMP/bat-$1"; mkrepo "$d"; cat > "$d/CLAUDE.md"; echo "$d"; }

bat() { # <label> <dir> <init-rc> <init-needle> <lock-rc> <lock-needle|""> <span: AGENTS.md|CLAUDE.md|none> <mode: agree|stricter|both>
  local label="$1" d="$2" xrc="$3" n1="$4" lxrc="$5" ln="$6" spanf="$7" mode="$8"
  local rc ba bc
  ba=$(sha "$d/AGENTS.md"); bc=$(sha "$d/CLAUDE.md")
  # The lock reads the fixture as it stands — before the init has touched it.
  lock_probe "$d/AGENTS.md" "$d/CLAUDE.md"
  rc=$(run "$d")
  [[ "$rc" == "$xrc" ]] && ok "$label — init exits $xrc" || fail "$label init rc" "rc=$rc out=$(cat "$OUT")"
  has "$OUT" "$n1" && ok "$label — init: $n1" || fail "$label init verdict" "$(cat "$OUT")"
  if [[ "$xrc" == "1" ]]; then
    if [[ "$ba" == "$(sha "$d/AGENTS.md")" && "$bc" == "$(sha "$d/CLAUDE.md")" \
       && ! -f "$d/docs/llm-orchestrator/cadence.json" && ! -f "$d/docs/llm-orchestrator/LOCK.sha256" ]]; then
      ok "$label — the refusal fired before the first byte"
    else fail "$label preflight" "$(ls -R "$d" 2>/dev/null | tr '\n' ' ')"; fi
  fi
  [[ "$LOCK_RC" == "$lxrc" ]] && ok "$label — --lock exits $lxrc" || fail "$label lock rc" "rc=$LOCK_RC $(cat "$TMP/lockprobe.log")"
  if [[ -n "$ln" ]]; then
    has "$TMP/lockprobe.log" "$ln" && ok "$label — --lock: $ln" || fail "$label lock reason" "$(cat "$TMP/lockprobe.log")"
  fi
  case "$spanf" in
    AGENTS.md) [[ -n "$LOCK_SECT_SHA" && "$LOCK_SECT_SHA" == "$(sect_sha "$d/AGENTS.md")" ]] \
      && ok "$label — the manifest hashes exactly the span of AGENTS.md" \
      || fail "$label span" "manifest=$LOCK_SECT_SHA span=$(sect_sha "$d/AGENTS.md")" ;;
    CLAUDE.md) [[ -n "$LOCK_SECT_SHA_C" && "$LOCK_SECT_SHA_C" == "$(sect_sha "$d/CLAUDE.md")" ]] \
      && ok "$label — the manifest hashes exactly the span of CLAUDE.md" \
      || fail "$label span" "manifest=$LOCK_SECT_SHA_C span=$(sect_sha "$d/CLAUDE.md")" ;;
    none) [[ -z "$LOCK_SECT_SHA" && -z "$LOCK_SECT_SHA_C" ]] \
      && ok "$label — the manifest carries no section entry" || fail "$label span" "a=$LOCK_SECT_SHA c=$LOCK_SECT_SHA_C" ;;
  esac
  case "$mode" in
    agree)    [[ "$rc" == "$LOCK_RC" ]] && ok "$label — agreement: both readers reach the same verdict" || fail "$label agree" "init=$rc lock=$LOCK_RC" ;;
    stricter) [[ "$rc" == "1" && "$LOCK_RC" == "0" ]] && ok "$label — recorded divergence: the init refuses; the lock would accept" || fail "$label stricter" "init=$rc lock=$LOCK_RC" ;;
    both)     [[ "$rc" == "1" && "$LOCK_RC" == "1" ]] && ok "$label — agreement: both refuse, by different terms" || fail "$label both" "init=$rc lock=$LOCK_RC" ;;
  esac
  # The one direction no shape may take: the lock refuses what the init accepted.
  [[ "$LOCK_RC" == "1" && "$rc" == "0" ]] && fail "$label unsafe" "the lock refuses a file the init accepted" \
    || ok "$label — never the unsafe direction (lock refuses, init accepts)"
}

FENCED='its <!-- ORCH:LAWS:START -->'
D=$(printf '# Agents\n\nHouse rules.\n' | mkbat s1)
bat "1 no markers" "$D" 0 'appended AGENTS.md (the ORCH:LAWS block)' 0 '' none agree

# The block source every kept fixture is built from, and the older version of
# it that shape 21 and the unlock scenes use — one re-worded bullet, the delta
# measured between two installs of this plugin.
older_block() { sed 's/^- Every dispatch names the model it runs on\.$/- Every dispatch states which model it runs on./' "$BLOCK"; }

D=$( { printf '# Agents\n\n'; cat "$BLOCK"; } | mkbat s2)
bat "2 one live pair carrying the block" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START -->\na\n<!-- ORCH:LAWS:END -->\n\n<!-- ORCH:LAWS:START -->\nb\n<!-- ORCH:LAWS:END -->\n' | mkbat s3)
bat "3 two live pairs" "$D" 1 'duplicate marker' 1 'duplicate marker' - agree

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START --> <!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n' | mkbat s4)
bat "4 two STARTs on one line" "$D" 1 'duplicate marker' 1 'duplicate marker' - agree

D=$( { printf '# Agents\n\n'; cat "$BLOCK"; printf '\nIt closes with <!-- ORCH:LAWS:END --> on a line of its own.\n'; } | mkbat s5)
bat "5 the block plus a stray END below" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree

D=$( { printf '# Agents\n\nIt closes with <!-- ORCH:LAWS:END --> on a line of its own.\n\n'; cat "$BLOCK"; } | mkbat s6)
bat "6 an END above the block" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n' | mkbat s7)
bat "7 START with no END" "$D" 1 'unterminated section' 1 'unterminated section' - agree

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:END -->\n\nTail.\n' | mkbat s8)
bat "8 END with no START" "$D" 1 'orphan end marker' 1 'orphan end marker' - agree

D=$(printf '# Agents\n\nWhat it adds:\n\n```\n<!-- ORCH:LAWS:START -->\nsample\n<!-- ORCH:LAWS:END -->\n```\n' | mkbat s9)
bat "9 wholly fenced pair" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

D=$(printf '# Agents\n\nIt opens with:\n\n```\n<!-- ORCH:LAWS:START -->\n```\n\nIt closes with <!-- ORCH:LAWS:END --> on a line of its own.\n' | mkbat s10)
bat "10 fenced START, live END" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n\nIt closes with:\n\n```\n<!-- ORCH:LAWS:END -->\n```\n' | mkbat s11)
bat "11 live START, fenced END" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

D=$(printf '# Agents\n\nIt opens with:\n\n```\n<!-- ORCH:LAWS:START -->\n```\n\nTail.\n' | mkbat s12)
bat "12 fenced lone START" "$D" 1 'unterminated section' 1 'unterminated section' - both

D=$(printf '# Agents\n\nIt closes with:\n\n```\n<!-- ORCH:LAWS:END -->\n```\n\nTail.\n' | mkbat s13)
bat "13 fenced lone END" "$D" 1 'orphan end marker' 1 'orphan end marker' - both

D=$(printf '# Agents\n\nWhat it adds:\n\n```\nsample\n\n<!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n' | mkbat s14)
bat "14 unclosed fence above a pair" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

D=$(printf '# Agents\n\nFor reference:\n\n    <!-- ORCH:LAWS:START -->\n    the laws\n    <!-- ORCH:LAWS:END -->\n\nTail.\n' | mkbat s15)
bat "15 4-space indented pair" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 16 — the same five fenced shapes written with ~~~, the fence syntax the awk
# tracks separately. A tilde fence must refuse exactly where a backtick one does.
D=$(printf '# Agents\n\nWhat it adds:\n\n~~~\n<!-- ORCH:LAWS:START -->\nsample\n<!-- ORCH:LAWS:END -->\n~~~\n' | mkbat s16a)
bat "16a tilde-fenced pair" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter
D=$(printf '# Agents\n\nIt opens with:\n\n~~~\n<!-- ORCH:LAWS:START -->\n~~~\n\nIt closes with <!-- ORCH:LAWS:END --> on a line of its own.\n' | mkbat s16b)
bat "16b tilde-fenced START, live END" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter
D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n\nIt closes with:\n\n~~~\n<!-- ORCH:LAWS:END -->\n~~~\n' | mkbat s16c)
bat "16c live START, tilde-fenced END" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter
D=$(printf '# Agents\n\nIt opens with:\n\n~~~\n<!-- ORCH:LAWS:START -->\n~~~\n\nTail.\n' | mkbat s16d)
bat "16d tilde-fenced lone START" "$D" 1 'unterminated section' 1 'unterminated section' - both
D=$(printf '# Agents\n\nIt closes with:\n\n~~~\n<!-- ORCH:LAWS:END -->\n~~~\n\nTail.\n' | mkbat s16e)
bat "16e tilde-fenced lone END" "$D" 1 'orphan end marker' 1 'orphan end marker' - both

D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n\nFor reference:\n\n```\n<!-- ORCH:LAWS:START -->\nsample\n<!-- ORCH:LAWS:END -->\n```\n' | mkbat s17)
bat "17 live pair plus a fenced sample below" "$D" 1 'duplicate marker' 1 'duplicate marker' - both

D=$(printf '# Agents\n\n<!-- see ORCH:LAWS:START --> is not the marker.\n' | mkbat s18)
bat "18 a near-miss marker in another comment" "$D" 0 'appended AGENTS.md (the ORCH:LAWS block)' 0 '' none agree

# 19 FLIPS 0 -> 1 under the content rule, and rightly: `kept` over a one-line
# pair armed a project whose agent-facing laws text was the empty string.
D=$(printf '# Agents\n\n<!-- ORCH:LAWS:START --> the laws <!-- ORCH:LAWS:END -->\n\nTail.\n' | mkbat s19)
bat "19 START and END on one line" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 20 — shapes 9 through 15 in CLAUDE.md. The manifest hashes that file's section
# too, so a marker in a code context there is the same hole in the same words.
D=$(printf '@AGENTS.md\n\n# Claude\n\n```\n<!-- ORCH:LAWS:START -->\nsample\n<!-- ORCH:LAWS:END -->\n```\n' | mkbatc s20a)
bat "20a fenced pair in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 0 '' CLAUDE.md stricter
D=$(printf '@AGENTS.md\n\n# Claude\n\n```\n<!-- ORCH:LAWS:START -->\n```\n\nIt closes with <!-- ORCH:LAWS:END --> on a line of its own.\n' | mkbatc s20b)
bat "20b fenced START, live END in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 0 '' CLAUDE.md stricter
D=$(printf '@AGENTS.md\n\n<!-- ORCH:LAWS:START -->\nthe laws\n\nIt closes with:\n\n```\n<!-- ORCH:LAWS:END -->\n```\n' | mkbatc s20c)
bat "20c live START, fenced END in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 0 '' CLAUDE.md stricter
D=$(printf '@AGENTS.md\n\n# Claude\n\n```\n<!-- ORCH:LAWS:START -->\n```\n\nTail.\n' | mkbatc s20d)
bat "20d fenced lone START in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 1 'unterminated section' - both
D=$(printf '@AGENTS.md\n\n# Claude\n\n```\n<!-- ORCH:LAWS:END -->\n```\n\nTail.\n' | mkbatc s20e)
bat "20e fenced lone END in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 1 'orphan end marker' - both
D=$(printf '@AGENTS.md\n\n# Claude\n\n```\nsample\n\n<!-- ORCH:LAWS:START -->\nthe laws\n<!-- ORCH:LAWS:END -->\n' | mkbatc s20f)
bat "20f unclosed fence above a pair in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 0 '' CLAUDE.md stricter
D=$(printf '@AGENTS.md\n\n# Claude\n\n    <!-- ORCH:LAWS:START -->\n    the laws\n    <!-- ORCH:LAWS:END -->\n\nTail.\n' | mkbatc s20g)
bat "20g 4-space indented pair in CLAUDE.md" "$D" 1 'refused CLAUDE.md' 0 '' CLAUDE.md stricter

# 21-29 — the shapes the CONTENT rule introduces. Every one carries the same
# lock probe and the same agreement mode as the shapes above it; the point of
# the new rows is that `kept` now means "this text IS the block", so the fixtures
# vary the TEXT and hold the marker positions still.

# 21 — an older version of the block: the same markers around one re-worded
# bullet. Measured between two installs of this plugin, so this is the drift
# case, not a hypothetical one. Its remedy is the unlock scene below.
D=$( { printf '# Agents\n\n'; older_block; } | mkbat s21)
bat "21 an older version of the block" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 22 — the block with CRLF line endings. CR counts as trailing whitespace, or
# every CRLF project is refused and then silently rewritten to LF.
D=$( { printf '# Agents\r\n\r\n'; awk '{ printf "%s\r\n", $0 }' "$BLOCK"; } | mkbat s22)
B22=$(sha "$D/AGENTS.md")
bat "22 the block with CRLF line endings" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree
[[ "$B22" == "$(sha "$D/AGENTS.md")" ]] && ok "22 — and that CRLF file is not rewritten to LF behind the kept verdict" || fail "22 crlf rewritten" "changed"

# 23 — the base case: the block, no wrapper. It is also the case the init's own
# output has to satisfy, so it is proved twice: as a fixture, and by appending
# with the init and reading the result back on a second run.
D=$(cat "$BLOCK" | mkbat s23)
bat "23 the block alone, no wrapper" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree
S23="$TMP/bat-s23b"; mkrepo "$S23"
printf '# Agents\n\nHouse rules.\n' > "$S23/AGENTS.md"
RC=$(run "$S23")
[[ "$RC" == "0" ]] && has "$OUT" 'appended AGENTS.md' && ok "23 — the init appends its own block" || fail "23 append" "rc=$RC out=$(cat "$OUT")"
RC=$(run "$S23")
[[ "$RC" == "0" ]] && has "$OUT" 'kept AGENTS.md' && ok "23 — and reads that block back as kept on the next run" || fail "23 reread" "rc=$RC out=$(cat "$OUT")"

# 24 — the residual, stated plainly: a fence around the WHOLE pair falls outside
# the span, so the file is KEPT and the two readers AGREE. The block is present
# byte for byte, the lock hashes the identical span, and the only cost is that a
# human renderer shows it as a code block.
D=$( { printf '# Agents\n\n```\n'; cat "$BLOCK"; printf '```\n'; } | mkbat s24)
bat "24 the exact block inside a fence — kept, and both readers agree" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree

# 25 — the whole block behind a blockquote prefix. Every interior line carries
# "> ", so it is not the block.
D=$( { printf '# Agents\n\n'; sed 's/^/> /' "$BLOCK"; } | mkbat s25)
S25="$D"
bat "25 the whole block inside a blockquote" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 26 — <pre> around the verbatim block is the same residual as 24; <pre> around
# an EMPTY pair is not the block and is refused.
D=$( { printf '# Agents\n\n<pre>\n'; cat "$BLOCK"; printf '</pre>\n'; } | mkbat s26a)
bat "26a <pre> around the verbatim block" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree
D=$(printf '# Agents\n\n<pre>\n<!-- ORCH:LAWS:START -->\n<!-- ORCH:LAWS:END -->\n</pre>\n' | mkbat s26b)
bat "26b <pre> around an empty pair" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 27 — trailing spaces and CR on some lines: tolerated, because the tolerance is
# [[:space:]] at end of line and nothing else.
D=$( { printf '# Agents\n\n'; awk 'NR % 3 == 0 { printf "%s  \r\n", $0; next } { print }' "$BLOCK"; } | mkbat s27)
bat "27 the block with trailing spaces and CR on some lines" "$D" 0 'kept AGENTS.md' 0 '' AGENTS.md agree

# 28 — an extra blank line inside the block. Interior lines are compared one for
# one, so a re-wrap is a different section.
D=$( { printf '# Agents\n\n'; awk 'NR == 3 { print "" } { print }' "$BLOCK"; } | mkbat s28)
bat "28 the block with an extra blank line" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

# 29 — the block indented four spaces. LEADING whitespace is content; only
# trailing whitespace is ignored.
D=$( { printf '# Agents\n\nFor reference:\n\n'; sed 's/^/    /' "$BLOCK"; } | mkbat s29)
bat "29 the block indented four spaces" "$D" 1 'is not the current cadence block' 0 '' AGENTS.md stricter

printf '\n%s== the unlock replaces a section that is not the block, whole and backed up ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose AGENTS.md carries an OLDER version of the block;
# when cadence-init.sh runs without the unlock; expect the refusal that names
# both remedies with the unlock first. When it runs under
# ORCH_CADENCE_UNLOCK=1; expect the WHOLE span — marker lines included —
# replaced by the current block, the old file kept as AGENTS.md.bak, that
# backup gitignored, and the recipe a replacement needs: a re-lock, then a
# commit whose message carries a numbered ruling.
U1="$TMP/unlock-drift"; mkrepo "$U1"; mkdir -p "$U1/docs/llm-orchestrator"
printf '# THE LAWS\n\nRuling 3 (2026-01-01, owner): this project was armed already.\n' > "$U1/docs/llm-orchestrator/LAWS.md"
{ printf '# Agents\n\n'; older_block; printf '\nTail.\n'; } > "$U1/AGENTS.md"
cp "$U1/AGENTS.md" "$TMP/u1.orig"
RC=$(run "$U1")
[[ "$RC" == "1" ]] && ok "without the unlock a drifted block is refused" || fail "u1 locked" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'ORCH_CADENCE_UNLOCK=1 to replace that section' && ok "and the refusal orders the unlock remedy before the destructive one" || fail "u1 remedy" "$(cat "$OUT")"
has "$OUT" "compared against $BLOCK" && ok "and names the block file it compared against" || fail "u1 source" "$(cat "$OUT")"
[[ "$(sha "$TMP/u1.orig")" == "$(sha "$U1/AGENTS.md")" ]] && ok "with AGENTS.md byte-identical" || fail "u1 mutated" "changed"
RC=$(runu "$U1")
[[ "$RC" == "0" ]] && ok "under the unlock the run completes" || fail "u1 exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'replaced AGENTS.md#ORCH:LAWS (backup AGENTS.md.bak, compared against ' \
  && ok "the report names the replaced section, its backup and the source it compared against" || fail "u1 line" "$(cat "$OUT")"
cmp -s "$TMP/u1.orig" "$U1/AGENTS.md.bak" && ok "the old file is kept byte for byte at AGENTS.md.bak" || fail "u1 bak" "missing or differs"
cmp -s <(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$U1/AGENTS.md") "$BLOCK" \
  && ok "and the span is now the block byte for byte" || fail "u1 section" "differs from $BLOCK"
[[ "$(head -1 "$U1/AGENTS.md")" == "# Agents" && "$(tail -1 "$U1/AGENTS.md")" == "Tail." ]] \
  && ok "with every byte outside the span untouched" || fail "u1 outside" "$(head -1 "$U1/AGENTS.md") .. $(tail -1 "$U1/AGENTS.md")"
has "$U1/.gitignore" 'AGENTS.md.bak*' && ok ".gitignore gains the section-backup shape" || fail "u1 gitignore" "$(cat "$U1/.gitignore" 2>/dev/null)"
has "$OUT" 'this run replaced an ORCH:LAWS section' && ok "the recipe says what this run did, not that the project is unarmed" || fail "u1 recipe head" "$(cat "$OUT")"
has "$OUT" 'NUMBERED RULING' && ok "and demands a numbered ruling in the commit message" || fail "u1 recipe" "$(cat "$OUT")"
has "$OUT" 'rewrote a section the manifest covers' && ok "and orders the re-lock under the unlock before it" || fail "u1 relock" "$(cat "$OUT")"
# The already-armed recipe is a different branch with different numbering, and
# a step added to one arm only is a step half the readers never see.
has "$OUT" 'in CI, run .githooks/orch-cadence-check.sh --audit HEAD' \
  && ok "and the replacement recipe carries the CI audit step too" || fail "u1 ci" "$(cat "$OUT")"

# Idempotence: a second run finds the interior equal, so it keeps and makes no
# second backup — without this the .bak.N scheme grows one file per run.
BEFORE=$(sha "$U1/AGENTS.md")
RC=$(runu "$U1")
[[ "$RC" == "0" ]] && ok "a second run under the unlock exits 0" || fail "u1b exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'kept AGENTS.md' && ok "and finds the section equal — kept, not replaced a second time" || fail "u1b kept" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$U1/AGENTS.md")" ]] && ok "with not one byte changed" || fail "u1b mutated" "changed"
[[ ! -e "$U1/AGENTS.md.bak.1" ]] && ok "and no second backup beside the first" || fail "u1b bak2" "$(ls -1 "$U1" | tr '\n' ' ')"

# The backup must not reach the commit: the arming commit is a `git add -A`.
( cd "$U1" && git add -A && git "${GIT_ID[@]}" commit -q -m "arm the cadence" ) > "$TMP/u1commit.log" 2>&1
TRACKED=$( cd "$U1" && git ls-files | grep -c '\.bak' )
[[ "$TRACKED" == "0" ]] && ok "the commit's tree carries no .bak" || fail "u1 bak tracked" "$( cd "$U1" && git ls-files | grep '\.bak' | tr '\n' ' ')"

# SCENE: given the blockquoted whole block (shape 25); when init runs under the
# unlock; expect the WHOLE span replaced, marker lines included — replacing only
# the interior would leave `> <!-- ...START -->` as the boundary and put
# un-prefixed block text inside somebody's blockquote.
RC=$(runu "$S25")
[[ "$RC" == "0" ]] && ok "the blockquoted sample is replaced under the unlock" || fail "u2 exit" "rc=$RC out=$(cat "$OUT")"
cmp -s <(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$S25/AGENTS.md") "$BLOCK" \
  && ok "and the whole span, marker lines included, is the block" || fail "u2 span" "$(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$S25/AGENTS.md" | head -3)"
QUOTED=$(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$S25/AGENTS.md" | grep -c '^> ')
[[ "$QUOTED" == "0" ]] && ok "no line of the replaced section still carries the blockquote prefix" || fail "u2 prefix" "$QUOTED quoted lines remain"

printf '\n%s== the content rule runs on CLAUDE.md too, both directions ==%s\n' "$DIM" "$RESET"
# SCENE: the manifest hashes CLAUDE.md#ORCH:LAWS as well, so a CLAUDE.md
# carrying the exact block is kept and one carrying anything else is refused —
# and the unlocked replacement is the one path on which this script ever writes
# the block into CLAUDE.md.
CK="$TMP/claude-block"; mkrepo "$CK"
{ printf '@AGENTS.md\n\n'; cat "$BLOCK"; } > "$CK/CLAUDE.md"
BEFORE=$(sha "$CK/CLAUDE.md")
RC=$(run "$CK")
[[ "$RC" == "0" ]] && ok "a CLAUDE.md carrying the exact block exits 0" || fail "cb exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'kept CLAUDE.md' && ok "and is kept" || fail "cb kept" "$(cat "$OUT")"
[[ "$BEFORE" == "$(sha "$CK/CLAUDE.md")" ]] && ok "with not one byte changed" || fail "cb mutated" "changed"

CDR="$TMP/claude-drift"; mkrepo "$CDR"
{ printf '@AGENTS.md\n\n'; older_block; } > "$CDR/CLAUDE.md"
cp "$CDR/CLAUDE.md" "$TMP/cd.orig"
RC=$(run "$CDR")
[[ "$RC" == "1" ]] && ok "a CLAUDE.md whose section is not the block exits 1" || fail "cd exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused CLAUDE.md' && ok "and the refusal names CLAUDE.md" || fail "cd reason" "$(cat "$OUT")"
[[ "$(sha "$TMP/cd.orig")" == "$(sha "$CDR/CLAUDE.md")" ]] && ok "with the file byte-identical behind it" || fail "cd mutated" "changed"
RC=$(runu "$CDR")
[[ "$RC" == "0" ]] && ok "under the unlock that run completes" || fail "cdu exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'replaced CLAUDE.md#ORCH:LAWS (backup CLAUDE.md.bak' && ok "and the CLAUDE.md section is replaced, with a backup" || fail "cdu line" "$(cat "$OUT")"
cmp -s "$TMP/cd.orig" "$CDR/CLAUDE.md.bak" && ok "the old CLAUDE.md is kept byte for byte" || fail "cdu bak" "missing or differs"
cmp -s <(sed -n '/<!-- ORCH:LAWS:START -->/,/<!-- ORCH:LAWS:END -->/p' "$CDR/CLAUDE.md") "$BLOCK" \
  && ok "and the block is now in CLAUDE.md byte for byte" || fail "cdu section" "differs"
has "$CDR/.gitignore" 'CLAUDE.md.bak*' && ok ".gitignore gains the CLAUDE.md backup shape too" || fail "cdu gitignore" "$(cat "$CDR/.gitignore" 2>/dev/null)"

printf '\n%s== --adopt buys no exemption from the content rule ==%s\n' "$DIM" "$RESET"
# SCENE: given --adopt over a project whose ORCH:LAWS section is an older block;
# when init runs; expect the same refusal — adopt keeps files the project owns,
# and the ORCH:LAWS section is the plugin's own text (a project's laws live in
# LAWS.md). Adopt plus the unlock still replaces.
AS="$TMP/adopt-section"; mkrepo "$AS"
{ printf '# Agents\n\n'; older_block; } > "$AS/AGENTS.md"
RC=$(run "$AS" --adopt)
[[ "$RC" == "1" ]] && ok "--adopt over a drifted block still exits 1" || fail "as exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'is not the current cadence block' && ok "with the same refusal" || fail "as reason" "$(cat "$OUT")"
RC=$(runu "$AS" --adopt)
[[ "$RC" == "0" ]] && ok "--adopt plus the unlock completes" || fail "asu exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'replaced AGENTS.md#ORCH:LAWS' && ok "and still replaces the section" || fail "asu line" "$(cat "$OUT")"

printf '\n%s== a target that is not a regular file is refused, FIFO included ==%s\n' "$DIM" "$RESET"
# SCENE: given .claude/settings.json that is a FIFO; when init runs; expect a
# preflight refusal naming the path — not six law and marker files on disk and
# a write that blocks on a reader that never comes. The probe runs under a
# timeout so a regression cannot hang this suite.
FIFOD="$TMP/fifoset"; mkrepo "$FIFOD"; mkdir -p "$FIFOD/.claude"
if mkfifo "$FIFOD/.claude/settings.json" 2>/dev/null; then
  bash "$INIT" --root "$FIFOD" > "$OUT" 2> "$ERR" &
  FPID=$!
  WAITED=0
  while kill -0 "$FPID" 2>/dev/null && [[ "$WAITED" -lt 50 ]]; do sleep 0.1; WAITED=$((WAITED+1)); done
  if kill -0 "$FPID" 2>/dev/null; then
    kill -9 "$FPID" 2>/dev/null
    # Release whatever child is blocked opening the FIFO for writing, so a red
    # run leaves no orphan behind.
    { cat "$FIFOD/.claude/settings.json" >/dev/null 2>&1 & }
    DPID=$!
    sleep 1
    kill -9 "$DPID" 2>/dev/null
    wait "$FPID" 2>/dev/null
    RC=124
  else
    wait "$FPID"; RC=$?
  fi
  [[ "$RC" == "1" ]] && ok "a FIFO at .claude/settings.json exits 1 without hanging" || fail "fifo exit" "rc=$RC (124 = still running after 5s) out=$(cat "$OUT")"
  has "$OUT" 'refused .claude/settings.json' && ok "the refusal names the path the special file sits at" || fail "fifo reason" "$(cat "$OUT")"
  has "$OUT" 'special file' && ok "and calls it a special file" || fail "fifo kind" "$(cat "$OUT")"
  [[ ! -f "$FIFOD/docs/llm-orchestrator/LAWS.md" && ! -f "$FIFOD/AGENTS.md" && ! -f "$FIFOD/CLAUDE.md" ]] \
    && ok "nothing is written ahead of the FIFO refusal" || fail "fifo partial" "$(ls -R "$FIFOD" 2>/dev/null | tr '\n' ' ')"
  has "$OUT" 'nothing was written' && ok "and the FIFO refusal says nothing was written" || fail "fifo silence" "$(cat "$OUT")"
else
  ok "mkfifo is unavailable here — the special-file probe is skipped"
fi

printf '\n%s== a stray second end marker is not a duplicate ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md with one complete ORCH:LAWS pair and a second end
# marker quoted in prose below it; when init runs; expect the run to proceed —
# the lock reads the first pair and accepts that file, and a preflight that
# refuses what the lock accepts blocks a project over a marker that is not there.
SE="$TMP/strayend"; mkrepo "$SE"
{ printf '# Agents\n\n'; cat "$BLOCK"; printf '\n'
  printf 'The section closes with <!-- ORCH:LAWS:END --> on a line of its own.\n'; } > "$SE/AGENTS.md"
RC=$(run "$SE")
[[ "$RC" == "0" ]] && ok "one pair plus a stray end marker initializes at exit 0" || fail "strayend exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'duplicate marker' && fail "strayend reason" "refused for a duplicate marker that is not in the file" || ok "and it is not refused as a duplicate marker"
has "$OUT" 'kept AGENTS.md' && ok "the file carrying the stray end marker is kept" || fail "strayend kept" "$(cat "$OUT")"
( cd "$SE" && ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$SE" --lock ) > "$TMP/strayend_lock.log" 2>&1
LRC=$?
[[ "$LRC" == "0" ]] && ok "and --lock over the same file succeeds" || fail "strayend lock" "rc=$LRC $(cat "$TMP/strayend_lock.log")"

printf '\n%s== the writability preflight covers the replacement path too ==%s\n' "$DIM" "$RESET"
# SCENE: given a project whose AGENTS.md is read-only and whose ORCH:LAWS
# section has drifted — the ordinary case, since every project armed with the
# previous block is refused by the next init — when cadence-init.sh runs under
# ORCH_CADENCE_UNLOCK=1; expect the preflight's own refusal with nothing
# written, not four law documents, a stray AGENTS.md.bak and a raw
# `Permission denied` line behind a refusal. A marker pair sets the action to
# `keep` on the branch that is about to REWRITE the file, so `keep` alone must
# not excuse the file from the writability check.
RO="$TMP/readonly-replace"; mkrepo "$RO"
{ printf '# Agents\n\n'; older_block; printf '\nTail.\n'; } > "$RO/AGENTS.md"
cp "$RO/AGENTS.md" "$TMP/ro.orig"
chmod 444 "$RO/AGENTS.md"
RC=$(runu "$RO")
[[ "$RC" == "1" ]] && ok "a read-only AGENTS.md with a drifted section exits 1 under the unlock" || fail "ro exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'refused AGENTS.md: it cannot be written to — check its permissions' \
  && ok "and the preflight's own permissions refusal is what prints" || fail "ro reason" "$(cat "$OUT")"
has "$OUT" 'nothing was written' && ok "with the report saying nothing was written" || fail "ro silence" "$(cat "$OUT")"
[[ ! -e "$RO/AGENTS.md.bak" ]] && ok "no backup is left beside the file it never rewrote" || fail "ro bak" "$(ls -1 "$RO" | tr '\n' ' ')"
[[ ! -f "$RO/docs/llm-orchestrator/LAWS.md" && ! -f "$RO/docs/llm-orchestrator/cadence.json" ]] \
  && ok "and no law document the project did not have" || fail "ro partial" "$(ls -R "$RO" 2>/dev/null | tr '\n' ' ')"
[[ "$(sha "$TMP/ro.orig")" == "$(sha "$RO/AGENTS.md")" ]] && ok "with AGENTS.md byte-identical" || fail "ro mutated" "changed"
has "$ERR" 'Permission denied' && fail "ro stderr" "a raw interpreter error reached the operator: $(cat "$ERR")" \
  || ok "and no raw interpreter line on stderr"
chmod u+w "$RO/AGENTS.md"
RC=$(runu "$RO")
[[ "$RC" == "0" ]] && ok "once the file is writable the same run completes" || fail "ro heal exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'replaced AGENTS.md#ORCH:LAWS' && ok "and replaces the drifted section" || fail "ro heal line" "$(cat "$OUT")"

# The CLAUDE.md twin: line 1 is already @AGENTS.md, so its action is `keep` too,
# and the replacement is the one path on which this script writes into it.
ROC="$TMP/readonly-replace-claude"; mkrepo "$ROC"
{ printf '# Agents\n\n'; cat "$BLOCK"; } > "$ROC/AGENTS.md"
{ printf '@AGENTS.md\n\n'; older_block; } > "$ROC/CLAUDE.md"
cp "$ROC/CLAUDE.md" "$TMP/roc.orig"
chmod 444 "$ROC/CLAUDE.md"
RC=$(runu "$ROC")
[[ "$RC" == "1" ]] && ok "a read-only CLAUDE.md with a drifted section exits 1 under the unlock" || fail "roc exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'refused CLAUDE.md: it cannot be written to — check its permissions' \
  && ok "and the CLAUDE.md arm refuses in the preflight's words too" || fail "roc reason" "$(cat "$OUT")"
has "$OUT" 'nothing was written' && ok "with nothing written on the CLAUDE.md arm either" || fail "roc silence" "$(cat "$OUT")"
has "$OUT" 'kept CLAUDE.md' && fail "roc kept" "the report claimed kept CLAUDE.md and then refused it" || ok "and no kept line for the file it could not rewrite"
[[ ! -e "$ROC/CLAUDE.md.bak" ]] && ok "no CLAUDE.md.bak beside it" || fail "roc bak" "$(ls -1 "$ROC" | tr '\n' ' ')"
[[ ! -f "$ROC/docs/llm-orchestrator/LAWS.md" ]] && ok "and no law document" || fail "roc partial" "$(ls -R "$ROC" 2>/dev/null | tr '\n' ' ')"
[[ "$(sha "$TMP/roc.orig")" == "$(sha "$ROC/CLAUDE.md")" ]] && ok "with CLAUDE.md byte-identical" || fail "roc mutated" "changed"
chmod u+w "$ROC/CLAUDE.md"
RC=$(runu "$ROC")
[[ "$RC" == "0" ]] && ok "once CLAUDE.md is writable the run completes" || fail "roc heal exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'replaced CLAUDE.md#ORCH:LAWS' && ok "and replaces the drifted CLAUDE.md section" || fail "roc heal line" "$(cat "$OUT")"

printf '\n%s== the replacement refuses an unclosed fence, as the append path does ==%s\n' "$DIM" "$RESET"
# SCENE: given an AGENTS.md whose last code fence is never closed and whose
# marker pair sits below that opener carrying something other than the block;
# when init runs under the unlock; expect the same refusal the append path
# gives that file — one tool, one file, one answer. Writing the block under an
# unclosed opener puts the laws on screen as sample code.
FRP="$TMP/fence-replace"; mkrepo "$FRP"
{ printf '# Agents\n\n```text\nan opener nobody closed\n\n'; older_block; printf '\nTail.\n'; } > "$FRP/AGENTS.md"
cp "$FRP/AGENTS.md" "$TMP/frp.orig"
RC=$(runu "$FRP")
[[ "$RC" == "1" ]] && ok "an unclosed fence above a drifted pair exits 1 under the unlock" || fail "frp exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused AGENTS.md: its last code fence is never closed' && ok "and the refusal names the unclosed fence" || fail "frp reason" "$(cat "$OUT")"
has "$OUT" 'replacing the block there would bury it inside the fence; close the fence, then re-run' \
  && ok "in the append path's words, with the replacement's own verb" || fail "frp verb" "$(cat "$OUT")"
has "$OUT" 'nothing was written' && ok "and says nothing was written" || fail "frp silence" "$(cat "$OUT")"
[[ ! -e "$FRP/AGENTS.md.bak" ]] && ok "with no backup left behind" || fail "frp bak" "$(ls -1 "$FRP" | tr '\n' ' ')"
[[ ! -f "$FRP/docs/llm-orchestrator/LAWS.md" ]] && ok "and no law document" || fail "frp partial" "$(ls -R "$FRP" 2>/dev/null | tr '\n' ' ')"
[[ "$(sha "$TMP/frp.orig")" == "$(sha "$FRP/AGENTS.md")" ]] && ok "and AGENTS.md byte-identical" || fail "frp mutated" "changed"

# The control: the same drifted pair under a fence that IS closed. Balanced
# fences must still replace, or the fix has simply blocked the unlock.
FRC="$TMP/fence-replace-closed"; mkrepo "$FRC"
{ printf '# Agents\n\n```text\na closed sample\n```\n\n'; older_block; printf '\nTail.\n'; } > "$FRC/AGENTS.md"
RC=$(runu "$FRC")
[[ "$RC" == "0" ]] && ok "a closed fence above a drifted pair still replaces under the unlock" || fail "frc exit" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
has "$OUT" 'replaced AGENTS.md#ORCH:LAWS' && ok "and the section becomes the block" || fail "frc line" "$(cat "$OUT")"

# The CLAUDE.md twin — the replacement writes there too, so the same gate holds.
FRCL="$TMP/fence-replace-claude"; mkrepo "$FRCL"
{ printf '# Agents\n\n'; cat "$BLOCK"; } > "$FRCL/AGENTS.md"
{ printf '@AGENTS.md\n\n~~~\nan opener nobody closed\n\n'; older_block; } > "$FRCL/CLAUDE.md"
cp "$FRCL/CLAUDE.md" "$TMP/frcl.orig"
RC=$(runu "$FRCL")
[[ "$RC" == "1" ]] && ok "an unclosed fence above a drifted CLAUDE.md pair exits 1" || fail "frcl exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'refused CLAUDE.md: its last code fence is never closed' && ok "and names CLAUDE.md" || fail "frcl reason" "$(cat "$OUT")"
[[ "$(sha "$TMP/frcl.orig")" == "$(sha "$FRCL/CLAUDE.md")" ]] && ok "with CLAUDE.md byte-identical" || fail "frcl mutated" "changed"

# The append path keeps its own verb: one shared test, two sentences.
FRA="$TMP/fence-append-verb"; mkrepo "$FRA"
printf '# Agents\n\n```text\nan opener nobody closed\n' > "$FRA/AGENTS.md"
RC=$(run "$FRA")
[[ "$RC" == "1" ]] && ok "the append path still refuses an unclosed fence" || fail "fra exit" "rc=$RC out=$(cat "$OUT")"
has "$OUT" 'appending the block there would bury it inside the fence; close the fence, then re-run' \
  && ok "and still says appending, not replacing" || fail "fra verb" "$(cat "$OUT")"

printf '\n%s== the real HOME is never written ==%s\n' "$DIM" "$RESET"
NOW_SHA=""
[[ -f "$REAL_HOME/.claude/settings.json" ]] && NOW_SHA="$(shasum -a 256 "$REAL_HOME/.claude/settings.json" 2>/dev/null | awk '{print $1}')"
[[ "$REAL_HOME_SHA" == "$NOW_SHA" ]] && ok "the operator's ~/.claude/settings.json is byte-identical after the suite" || fail "real HOME touched" "$REAL_HOME_SHA -> $NOW_SHA"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-init%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-cadence-init — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
