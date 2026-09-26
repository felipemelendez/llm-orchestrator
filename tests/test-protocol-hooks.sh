#!/usr/bin/env bash
# End-to-end tests for the actual hook script:
#   scripts/hooks/subagent-stop.sh
#
# Drives the real hook executables with temp JSONL transcripts in both
# content schemas (string and array-of-blocks). Validates:
#
#   subagent-stop:
#     (f) Status: DONE + Summary: string schema → PASS exit 0
#     (g) Status: DONE + Summary: array-of-blocks schema → PASS exit 0
#     (h) Status: BLOCKED without Need: → warn stderr exit 0
#     (i) Status: BLOCKED without Need: under ORCH_STRICT_STATUS=1 → exit 2
#     (j) no Status: block in transcript → warn exit 0
#
#   fail-open:
#     (k) missing transcript path → exit 0 (fail-open)
#     (l) ORCH_HOOK_PROFILE=minimal → exit 0 (skipped)
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBAGENT="${ROOT}/scripts/hooks/subagent-stop.sh"

# Legacy hook events carry no cwd; run them inside a disposable directory so the
# launching checkout's own cadence policy cannot select the vocabulary.
ISOLATED_CWD=$(mktemp -d)
cd "$ISOLATED_CWD" || exit 1
export CLAUDE_PROJECT_DIR="$ISOLATED_CWD"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Write a JSONL file with a single assistant message using the string schema.
# Usage: write_string_jsonl <path> <content_string>
write_string_jsonl() {
  local path="$1" content="$2"
  python3 -c "
import json, sys
content = sys.argv[1]
print(json.dumps({'role': 'assistant', 'content': content}))
" "$content" > "$path"
}

# Write a JSONL file with a single assistant message using the array-of-blocks schema.
# Usage: write_blocks_jsonl <path> <text_string>
write_blocks_jsonl() {
  local path="$1" text="$2"
  python3 -c "
import json, sys
text = sys.argv[1]
print(json.dumps({'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}))
" "$text" > "$path"
}

# pipe_to_hook <hook_path> <transcript_path> [env_overrides...]
# Pipes the hook event JSON to the hook, returns its exit code.
# Stdout/stderr captured and discarded; use check_hook_* helpers for assertions.
# Set PIPE_AGENT_TYPE to include an "agent_type" field (SubagentStop always
# carries one on the current harness; the validator scopes its checks by it).
PIPE_AGENT_TYPE=""
mk_hook_input() { # <transcript>
  if [[ -n "$PIPE_AGENT_TYPE" ]]; then
    printf '{"transcript_path":"%s","agent_type":"%s"}' "$1" "$PIPE_AGENT_TYPE"
  else
    printf '{"transcript_path":"%s"}' "$1"
  fi
}
pipe_hook_exit() {
  local hook="$1" transcript="$2"; shift 2
  env "$@" bash "$hook" < <(mk_hook_input "$transcript") >/dev/null 2>&1
  return $?
}

pipe_hook_all() {
  local hook="$1" transcript="$2"; shift 2
  local rc=0
  local out
  out=$(env "$@" bash "$hook" < <(mk_hook_input "$transcript") 2>&1) || rc=$?
  printf '%s' "$out"
  return $rc
}

# Temporary files (macOS-compatible: no suffix with mktemp)
T_STRING=$(mktemp /tmp/orch-test-hook-string-XXXXXX)
T_BLOCKS=$(mktemp /tmp/orch-test-hook-blocks-XXXXXX)
T_MULTI=$(mktemp /tmp/orch-test-hook-multi-XXXXXX)
cleanup() { rm -f "$T_STRING" "$T_BLOCKS" "$T_MULTI"; rm -rf "$ISOLATED_CWD"; }
trap cleanup EXIT

printf '\n%s== SubagentStop hook (subagent-stop.sh) ==%s\n' "$DIM" "$RESET"

# The validator scopes its shape checks by agent_type; these cases simulate an
# implementer return (the agent whose contract is the Status block).
PIPE_AGENT_TYPE="llm-orchestrator:orch-implementer"

DONE_REPLY="$(printf 'Status: DONE\nSummary: completed the task\nChanged:\n- foo:1\nVerify:\n- ok')"
BLOCKED_NO_NEED="$(printf 'Status: BLOCKED\nSummary: cannot proceed')"

# (f) Status: DONE + Summary: string schema → PASS exit 0
write_string_jsonl "$T_STRING" "$DONE_REPLY"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_STRING" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(f) DONE+Summary string schema → exit 0"
else fail "(f) DONE+Summary string schema" "expected exit 0, got $rc"; fi

# (g) Status: DONE + Summary: array-of-blocks schema → PASS exit 0
write_blocks_jsonl "$T_BLOCKS" "$DONE_REPLY"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_BLOCKS" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(g) DONE+Summary array-of-blocks schema → exit 0"
else fail "(g) DONE+Summary array-of-blocks schema" "expected exit 0, got $rc"; fi

# (h) Status: BLOCKED without Need: → warn stderr exit 0
write_string_jsonl "$T_STRING" "$BLOCKED_NO_NEED"
out=$(pipe_hook_all "$SUBAGENT" "$T_STRING" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "without a valid Status"; then
  ok "(h) BLOCKED without Need: → warn exit 0"
else
  fail "(h) BLOCKED without Need:" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (i) Status: BLOCKED without Need: under ORCH_STRICT_STATUS=1 → exit 2
write_string_jsonl "$T_STRING" "$BLOCKED_NO_NEED"
out=$(pipe_hook_all "$SUBAGENT" "$T_STRING" ORCH_STRICT_STATUS=1 2>&1); rc=$?
if [[ $rc -eq 2 ]] && printf '%s' "$out" | grep -q '"decision":"block"'; then
  ok "(i) BLOCKED without Need: strict → exit 2 + decision:block"
else
  fail "(i) BLOCKED without Need: strict" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j) no Status: block in transcript → warn exit 0
write_string_jsonl "$T_STRING" "I did some work but forgot the Status block."
out=$(pipe_hook_all "$SUBAGENT" "$T_STRING" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "without a valid Status"; then
  ok "(j) no Status block → warn exit 0"
else
  fail "(j) no Status block" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j2) last_assistant_message present but EMPTY → premature-termination warn.
out=$(printf '{"agent_type":"llm-orchestrator:orch-implementer","last_assistant_message":""}' \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "premature termination"; then
  ok "(j2) empty last_assistant_message → premature-termination warn, exit 0"
else
  fail "(j2) empty final message" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi
out=$(printf '{"agent_type":"llm-orchestrator:orch-implementer","last_assistant_message":""}' \
      | ORCH_STRICT_STATUS=1 bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 2 ]] && printf '%s' "$out" | grep -q '"decision":"block"'; then
  ok "(j2b) empty final message + strict → exit 2 (subagent told to keep working)"
else
  fail "(j2b) empty strict" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j3) last_assistant_message carries a valid DONE — no transcript needed.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': 'Status: DONE\nSummary: done via field\nVerify: npm test → 12 passed'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
  ok "(j3) valid DONE via last_assistant_message field → silent exit 0"
else
  fail "(j3) DONE via field" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j3b) DONE is a completion claim, so it carries the verification burden. A
# DONE with no Verify: used to pass deterministically and had to be caught by an
# LLM validator on every implementer return; it is now caught here, for free.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': 'Status: DONE\nSummary: done via field'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'requires a "Verify:" line'; then
  ok "(j3b) DONE without Verify: → warned deterministically"
else
  fail "(j3b) DONE without Verify" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j3c) A Verify: whose evidence sits on the FOLLOWING line is valid protocol.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': 'Status: DONE\nSummary: ok\nVerify:\n- \`npm test\` → 12 passed'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
  ok "(j3c) multi-line Verify: block accepted (content on the next line)"
else
  fail "(j3c) multi-line Verify" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j3d) A bare Verify: with nothing under it is not evidence. Note the section
# ends at a TOP-LEVEL shape header, not at any sub-label: `Verify:` followed by
# `Summary: npm test → 40 passed` is evidence, and treating a sub-label as a
# terminator warned replies that had pasted exactly what was asked for.
# Fence built with chr(96) — literal backticks inside this double-quoted shell
# string are command substitution: on Linux the substitution garbage split the
# python source across lines (SyntaxError), and on macOS it silently mangled
# the fixture. The check only ever passed by accident.
out=$(python3 -c "
import json
fence = chr(96) * 3
msg = 'Status: DONE\nSummary: ok\nVerify:\n\n' + fence + '\n' + fence
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': msg}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if printf '%s' "$out" | grep -q 'requires a "Verify:" line'; then
  ok "(j3d) empty Verify: section → still warned"
else
  fail "(j3d) empty Verify" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j4) reviewer scoping: Issues: reply is that agent's valid shape; prose is not.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-spec-reviewer',
                  'last_assistant_message': 'Issues:\n- none found'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
  ok "(j4) reviewer Issues: reply → silent (Status block not demanded of reviewers)"
else
  fail "(j4) reviewer Issues:" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-spec-reviewer',
                  'last_assistant_message': 'looks fine to me overall'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q "protocol shape"; then
  ok "(j4b) reviewer free prose → shape warn"
else
  fail "(j4b) reviewer prose" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j5) PARTIAL: valid with Progress:+Remaining:; invalid when Remaining: missing.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': 'Status: PARTIAL\nProgress:\n- step 1 done\nRemaining:\n- step 2'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
  ok "(j5) PARTIAL with Progress:+Remaining: → silent exit 0"
else
  fail "(j5) PARTIAL valid" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'llm-orchestrator:orch-implementer',
                  'last_assistant_message': 'Status: PARTIAL\nProgress:\n- step 1 done'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'Remaining:'; then
  ok "(j5b) PARTIAL missing Remaining: → warn names the missing line"
else
  fail "(j5b) PARTIAL invalid" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

# (j6) non-plugin agent (e.g. native Explore): free prose is NOT graded.
out=$(python3 -c "
import json
print(json.dumps({'agent_type': 'Explore',
                  'last_assistant_message': 'here are the files I found: a.ts, b.ts'}))" \
      | bash "$SUBAGENT" 2>&1); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
  ok "(j6) native agent free prose → silent (no shape contract imposed)"
else
  fail "(j6) native agent" "exit=$rc out=$(printf '%s' "$out" | head -1)"
fi

printf '\n%s== Broader schema coverage ==%s\n' "$DIM" "$RESET"

# (m) thinking+text multi-block: thinking block then text with valid Status: DONE
# orch_extract_last_assistant_text should concatenate only text blocks.
python3 -c "
import json
text = 'Status: DONE\nSummary: completed ok'
obj = {'role': 'assistant', 'content': [
    {'type': 'thinking', 'thinking': 'Let me think about this...'},
    {'type': 'text', 'text': text}
]}
print(json.dumps(obj))
" > "$T_MULTI"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_MULTI" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(m) thinking+text multi-block → Status DONE extracted → exit 0"
else fail "(m) thinking+text multi-block" "expected exit 0, got $rc"; fi

# (n) text+tool_use multi-block: a text block followed by a tool_use block.
# Extraction must still see the text.
python3 -c "
import json
text = 'Status: DONE\nSummary: text precedes a tool_use block'
obj = {'role': 'assistant', 'content': [
    {'type': 'text', 'text': text},
    {'type': 'tool_use', 'id': 'tool_abc', 'name': 'Bash', 'input': {'command': 'ls'}}
]}
print(json.dumps(obj))
" > "$T_MULTI"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_MULTI" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(n) text+tool_use multi-block -> Status: DONE extracted -> exit 0"
else fail "(n) text+tool_use multi-block" "expected exit 0, got $rc"; fi

# (o) Extra keys on assistant object (id, model) — extraction is key-order-independent.
python3 -c "
import json
text = 'Status: DONE\nSummary: key-order-independent extraction works'
obj = {'id': 'msg_xyz', 'model': 'claude-opus-4', 'role': 'assistant',
       'stop_reason': 'end_turn', 'content': text}
print(json.dumps(obj))
" > "$T_MULTI"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_MULTI" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(o) extra keys on assistant object (id, model) → exit 0"
else fail "(o) extra keys on assistant object" "expected exit 0, got $rc"; fi

# (p) multi-block with two text blocks concatenated — both parts together form Status: DONE.
python3 -c "
import json
obj = {'role': 'assistant', 'content': [
    {'type': 'text', 'text': 'Status: DONE\n'},
    {'type': 'text', 'text': 'Summary: two text blocks joined\n'}
]}
print(json.dumps(obj))
" > "$T_MULTI"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_MULTI" || rc=$?
if [[ $rc -eq 0 ]]; then ok "(p) two text blocks concatenated form valid Status: DONE → exit 0"
else fail "(p) two text blocks concatenated" "expected exit 0, got $rc"; fi

# python3 guard: run the hooks BEHAVIORALLY under a PATH shim without python3
# (the approach test-install.sh's P8 section uses for node). The old check
# grepped the hooks' SOURCE for the guard's strings, so changing the guard to
# `if false; then` while keeping the strings in a comment left both ticks
# green — a test of the text, not of the behavior. The transcript would BLOCK
# under the strict env, so exit 0 also proves the guard short-circuits BEFORE
# strict enforcement; the notice on stderr proves the guard branch (not an
# accidental fail-open further down) is what ran.
write_string_jsonl "$T_STRING" "just prose no header"
NOPY=$(mktemp -d /tmp/orch-test-nopy-XXXXXX)
for t in sh grep sed head cat dirname wc tr mkdir rm date uname awk tail cut find sort; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOPY/$t"
done
rc=0
out=$(env ORCH_STRICT_STATUS=1 PATH="$NOPY" "$BASH" "$SUBAGENT" < <(mk_hook_input "$T_STRING") 2>&1) || rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'python3 not found'; then
  ok "(q) subagent-stop: python3 absent → fail-open exit 0 with notice (behavioral)"
else
  fail "(q) subagent-stop python3-absent behavior" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
rm -rf "$NOPY"

printf '\n%s== Fail-open and profile gate ==%s\n' "$DIM" "$RESET"

# (k) missing transcript path → exit 0 (fail-open)
rc=0
bash "$SUBAGENT" < <(printf '{"transcript_path":"/tmp/this-file-does-not-exist-orch-test.jsonl"}') >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then ok "(k) subagent-stop: missing transcript → fail-open exit 0"
else fail "(k) subagent-stop: missing transcript" "expected exit 0, got $rc"; fi

# (l) the minimal hook profile skips the hook entirely -> exit 0
write_string_jsonl "$T_STRING" "just prose no header"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_STRING" ORCH_HOOK_PROFILE=minimal ORCH_STRICT_STATUS=1 || rc=$?
if [[ $rc -eq 0 ]]; then ok "(l) subagent-stop: ORCH_HOOK_PROFILE=minimal → exit 0 (skipped)"
else fail "(l) subagent-stop: ORCH_HOOK_PROFILE=minimal" "expected exit 0, got $rc"; fi

printf '\n%s== ORCH_HOOK_PROFILE=strict actually blocks ==%s\n' "$DIM" "$RESET"
# ARCHITECTURE.md has always documented `strict` as "all hooks active AND
# blocking", but nothing branched on it: blocking came only from the separate
# ORCH_STRICT_* knobs, so setting the profile bought the documented word and
# none of the behaviour. Measured before the fix: PROFILE=strict ALLOWED on
# subagent-stop while the explicit flag blocked.
write_string_jsonl "$T_STRING" "$BLOCKED_NO_NEED"
PIPE_AGENT_TYPE="llm-orchestrator:orch-implementer"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_STRING" ORCH_HOOK_PROFILE=strict || rc=$?
[[ $rc -eq 2 ]] && ok "subagent-stop: PROFILE=strict blocks a malformed Status block" \
  || fail "subagent-stop PROFILE=strict" "expected exit 2, got $rc"
rc=0; pipe_hook_exit "$SUBAGENT" "$T_STRING" ORCH_HOOK_PROFILE=strict ORCH_STRICT_STATUS=0 || rc=$?
[[ $rc -eq 0 ]] && ok "subagent-stop: an explicit ORCH_STRICT_STATUS=0 still opts out" \
  || fail "subagent-stop strict opt-out" "expected exit 0, got $rc"

printf '\n%s== Direct extraction assertions ==%s\n' "$DIM" "$RESET"
LIB="${ROOT}/scripts/lib/orch-protocol.sh"

# (r) bleed-through: two assistant lines; last is pure tool_use (no text block).
# orch_extract_last_assistant_text MUST return empty, not the prior assistant's text.
T_BLEED=$(mktemp /tmp/orch-test-bleed-XXXXXX)
python3 -c "
import json
line1 = json.dumps({'role': 'assistant', 'content': 'Status: DONE\nSummary: ok'})
line2 = json.dumps({'role': 'assistant', 'content': [{'type': 'tool_use', 'name': 'x', 'input': {}}]})
print(line1)
print(line2)
" > "$T_BLEED"
bleed_result=$(bash -c "source '$LIB'; orch_extract_last_assistant_text '$T_BLEED'")
if [[ -z "$bleed_result" ]]; then
  ok "(r) bleed-through: trailing tool_use message → extracted text is empty (not stale)"
else
  fail "(r) bleed-through: trailing tool_use message" \
       "expected empty; got: $(printf '%s' "$bleed_result" | head -1)"
fi
rm -f "$T_BLEED"

# (s) direct extraction: thinking+text multi-block → text equals expected.
T_DIRECT=$(mktemp /tmp/orch-test-direct-XXXXXX)
python3 -c "
import json
text = 'Status: DONE\nSummary: completed ok'
obj = {'role': 'assistant', 'content': [
    {'type': 'thinking', 'thinking': 'thinking...'},
    {'type': 'text', 'text': text}
]}
print(json.dumps(obj))
" > "$T_DIRECT"
direct_result=$(bash -c "source '$LIB'; orch_extract_last_assistant_text '$T_DIRECT'")
if printf '%s' "$direct_result" | grep -q 'Status: DONE'; then
  ok "(s) direct extraction: thinking+text → returned text contains 'Status: DONE'"
else
  fail "(s) direct extraction: thinking+text" \
       "expected 'Status: DONE' in output; got: $(printf '%s' "$direct_result" | head -1)"
fi

# (t) direct extraction: text+tool_use → text equals text block only.
python3 -c "
import json
text = 'Changed:\n- foo:1 -- fix\n\nVerify:\n- bash tests/smoke.sh -> pass'
obj = {'role': 'assistant', 'content': [
    {'type': 'text', 'text': text},
    {'type': 'tool_use', 'id': 'tool_abc', 'name': 'Bash', 'input': {'command': 'ls'}}
]}
print(json.dumps(obj))
" > "$T_DIRECT"
direct_result=$(bash -c "source '$LIB'; orch_extract_last_assistant_text '$T_DIRECT'")
if printf '%s' "$direct_result" | grep -q 'Changed:'; then
  ok "(t) direct extraction: text+tool_use → returned text contains 'Changed:'"
else
  fail "(t) direct extraction: text+tool_use" \
       "expected 'Changed:' in output; got: $(printf '%s' "$direct_result" | head -1)"
fi

# (u) direct extraction: two text blocks concatenated → joined text present.
python3 -c "
import json
obj = {'role': 'assistant', 'content': [
    {'type': 'text', 'text': 'Status: DONE\n'},
    {'type': 'text', 'text': 'Summary: two text blocks joined\n'}
]}
print(json.dumps(obj))
" > "$T_DIRECT"
direct_result=$(bash -c "source '$LIB'; orch_extract_last_assistant_text '$T_DIRECT'")
if printf '%s' "$direct_result" | grep -q 'Summary: two text blocks joined'; then
  ok "(u) direct extraction: two text blocks → concatenated text present"
else
  fail "(u) direct extraction: two text blocks" \
       "expected 'Summary: two text blocks joined'; got: $(printf '%s' "$direct_result" | head -1)"
fi

# (v) direct extraction: extra keys on assistant object (id, model) → string content returned.
python3 -c "
import json
text = 'Status: DONE\nSummary: key-order-independent extraction works'
obj = {'id': 'msg_xyz', 'model': 'claude-opus-4', 'role': 'assistant',
       'stop_reason': 'end_turn', 'content': text}
print(json.dumps(obj))
" > "$T_DIRECT"
direct_result=$(bash -c "source '$LIB'; orch_extract_last_assistant_text '$T_DIRECT'")
if printf '%s' "$direct_result" | grep -q 'key-order-independent extraction works'; then
  ok "(v) direct extraction: extra keys on assistant object → content returned correctly"
else
  fail "(v) direct extraction: extra keys on assistant object" \
       "expected text in output; got: $(printf '%s' "$direct_result" | head -1)"
fi
rm -f "$T_DIRECT"

# ============================================================
# Summary
# ============================================================
printf '\n%s== proportional completion vocabulary ==%s\n' "$DIM" "$RESET"
if python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="orch-protocol-policy-") as tmp:
    project = pathlib.Path(tmp) / "project"
    config = project / "docs/llm-orchestrator/cadence.json"
    config.parent.mkdir(parents=True)
    child = project / "child"
    child.mkdir()
    subprocess.run(["git", "init", "-q", str(project)], check=True)
    env = dict(os.environ, ORCH_HOOK_PROFILE="strict", ORCH_HOME=str(pathlib.Path(tmp) / "private"))
    # CLAUDE_PROJECT_DIR would win over the event's cwd; drop it so the hook
    # starts from cwd (a subdirectory) and walks up to the project.
    for key in ("ORCH_STRICT_STATUS", "ORCH_HOOK_DRY_RUN", "ORCH_DISABLED_HOOKS", "CLAUDE_PROJECT_DIR"):
        env.pop(key, None)

    def grade(hook, reply, expected=0, cwd=child):
        event = {"cwd": str(cwd), "last_assistant_message": reply,
                 "agent_type": "llm-orchestrator:orch-implementer"}
        result = subprocess.run(["bash", str(root / "scripts/hooks" / hook)], input=json.dumps(event),
                                capture_output=True, text=True, env=env, cwd=root)
        assert result.returncode == expected, (hook, reply, expected, result.returncode, result.stdout, result.stderr)
        return result

    # subagent-stop is the hook that reads the completion vocabulary.
    def both(line, expected=0):
        grade("subagent-stop.sh", "Status: DONE\nSummary: Updated behavior.\n" + line, expected)

    config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
    for verdict in ("PASS", "PENDING", "BLOCKED", "NOT APPLICABLE"):
        for separator in ("—", "–", "-"):
            both(f"Verification: {verdict} {separator} truthful disposition")
    grade("subagent-stop.sh", "Status: DONE_WITH_CONCERNS\nConcerns: Pending acceptance.\nVerification: PENDING — device unavailable")
    for malformed in ("Verification:", "Verification: PASS", "Verification: PASS — ",
                      "Verification: MAYBE — uncertain", "Verify: tests passed", "no verification needed (cosmetic)",
                      "```\nVerification: PASS — quoted example\n```",
                      "~~~\nVerification: PASS — quoted example\n~~~",
                      "    Verification: PASS — indented example"):
        both(malformed, 2)
    grade("subagent-stop.sh", "Status: DONE\nSummary:\nVerification: PASS — tests passed", 2)

    # A project's workflow comes from config, not text or inherited opt-in.
    for data in ({"enabled": False, "workflow": "proportional"},
                 {"enabled": "true", "workflow": "proportional"}):
        config.write_text(json.dumps(data))
        both("Verification: PASS — use proportional please", 2)
        both("Verify: tests passed")
    # An enabled config with a missing or other workflow is an error: the hook
    # says so in one line and grades neither format, rather than acting as if
    # there were no cadence.
    for data in ({"enabled": True}, {"enabled": True, "workflow": "legacy"},
                 {"enabled": True, "workflow": "typo"}):
        config.write_text(json.dumps(data))
        for reply in ("Verification: PASS — use proportional please", "Verify: tests passed"):
            r = grade("subagent-stop.sh", "Status: DONE\nSummary: Updated behavior.\n" + reply, 0)
            assert 'needs "workflow": "proportional"' in r.stdout + r.stderr, (data, r.stdout, r.stderr)
    config.unlink()
    both("Verification: PASS — workflow proportional claimed in prose", 2)
    both("Verify: tests passed")
print("proportional and non-cadence hook fixtures passed")
PY
then ok "shared completion vocabulary is selected by project config; any other config keeps the Verify: format"
else fail "proportional protocol hooks" "config-backed end-to-end fixture failed"; fi

printf '\n%s== Captured SubagentStop payloads (SubagentHandback) ==%s\n' "$DIM" "$RESET"
# Captured from Claude Code 2.1.282: in auto mode the explorer sent its report
# through SubagentHandback and last_assistant_message was "Report delivered to
# caller.".
MAT="${ROOT}/tests/fixtures/subagent-handback/materialize.py"
cap_fire() { # <mode> [materialize args...] -> "rc|stderr"
  local dir; dir=$(mktemp -d)
  local out rc
  out=$(python3 "$MAT" "$@" "$dir" | bash "$SUBAGENT" 2>&1 1>/dev/null); rc=$?
  rm -rf "$dir"
  printf '%s|%s' "$rc" "$out"
}
cap_dir=$(mktemp -d)
python3 "$MAT" auto "$cap_dir" > "$cap_dir/payload.json"
report=$(bash -c "source '$LIB'; orch_subagent_report '$cap_dir/payload.json'")
rm -rf "$cap_dir"
if [[ "$report" == "1Found:"* && "$report" != *"Report delivered"* ]]; then
  ok "orch_subagent_report returns the SubagentHandback message, not the closing text"
else
  fail "orch_subagent_report on captured auto payload" "got: $(printf '%s' "$report" | head -1)"
fi
out=$(cap_fire auto)
if [[ "$out" == "0|" ]]; then ok "auto-mode explorer with a valid handback report → silent"
else fail "captured auto payload" "out='$out'"; fi
out=$(cap_fire auto --no-agent-path)
if [[ "$out" == "0|" ]]; then ok "no agent_transcript_path → subagent transcript found from transcript_path + agent_id"
else fail "captured auto payload, derived path" "out='$out'"; fi
out=$(cap_fire auto --report "here is what I found: calc.py")
if [[ "${out%%|*}" == "0" && "$out" == *"here is what I found"* && "$out" != *"Report delivered"* ]]; then
  ok "badly shaped handback report → warns about the report itself"
else fail "captured auto payload, bad report" "out='$out'"; fi
out=$(cap_fire auto --agent-type llm-orchestrator:orch-implementer --report "Status: BLOCKED")
if [[ "${out%%|*}" == "0" && "$out" == *'Status: BLOCKED requires a "Need:"'* ]]; then
  ok "implementer handback report is graded against the Status contract"
else fail "captured auto payload, implementer" "out='$out'"; fi
out=$(cap_fire default)
if [[ "${out%%|*}" == "0" && "$out" == *"returns the sum"* ]]; then
  ok "default mode (no handback) → last_assistant_message is graded"
else fail "captured default payload" "out='$out'"; fi
out=$(cap_fire auto --append '"str"' --append '[1,2]')
if [[ "$out" == "0|" ]]; then ok "transcript lines that are JSON but not objects are skipped"
else fail "captured auto payload, non-object lines" "out='$out'"; fi
out=$(cap_fire auto --handback-input '[1,2]')
if [[ "${out%%|*}" == "0" && "$out" == *"Report delivered to caller."* ]]; then
  ok "SubagentHandback input that is not an object → falls back to last_assistant_message"
else fail "captured auto payload, non-object handback input" "out='$out'"; fi
out=$(cap_fire auto --append '{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>\nnote\n</system-reminder>"}}')
if [[ "$out" == "0|" ]]; then ok "harness-injected isMeta entry after the handback keeps the handback"
else fail "captured auto payload, isMeta after handback" "out='$out'"; fi
out=$(cap_fire auto --append '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<task-notification>done</task-notification>"}]}}')
if [[ "$out" == "0|" ]]; then ok "<task-notification> entry after the handback keeps the handback"
else fail "captured auto payload, task-notification after handback" "out='$out'"; fi
out=$(cap_fire auto --append '{"type":"user","message":{"role":"user","content":"Please also check sub.py"}}')
if [[ "${out%%|*}" == "0" && "$out" == *"Report delivered to caller."* ]]; then
  ok "a person's prompt after the handback discards it (resumed agent)"
else fail "captured auto payload, prompt after handback" "out='$out'"; fi
out=$(cap_fire auto --append '{"type":"user","message":{"role":"user","content":"<div> in header.vue is misaligned"}}')
if [[ "${out%%|*}" == "0" && "$out" == *"Report delivered to caller."* ]]; then
  ok "a person's prompt that starts with a tag still discards it"
else fail "captured auto payload, tag-led prompt after handback" "out='$out'"; fi
out=$(cap_fire auto --handback-error)
if [[ "${out%%|*}" == "0" && "$out" == *"Report delivered to caller."* ]]; then
  ok "a SubagentHandback call answered by an error does not count"
else fail "captured auto payload, handback error" "out='$out'"; fi

TOTAL=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d checks passed.%s\n' "$GREEN" "$TOTAL" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
