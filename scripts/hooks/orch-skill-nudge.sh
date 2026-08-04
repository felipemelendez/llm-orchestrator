#!/usr/bin/env bash
# LLM Orchestrator skill-nudge hook (UserPromptSubmit).
# Deterministically detects a bug-shaped user prompt and injects one line of
# additionalContext telling the agent to invoke systematic-debugging before
# proposing a fix, and test-driven-development for the covering test.
#
# Why this exists: transcript mining (2026-08-04) showed the plugin's
# pressure-resistant testing behavior flows through skill invocation — runs
# that invoked systematic-debugging/test-driven-development wrote the covering
# test 76/77 times (~99%), but prose triggers fired in only ~23% of bug-shaped
# runs. A hook fires deterministically; prose fires when the model feels like
# it. Same principle as the git guards: enforce in the harness, don't plead in
# prose.
#
# Precision beats recall: a false nudge on every message trains the model to
# ignore the channel and costs context. Only high-precision imperative-bug
# shapes fire; slash commands, how-does-this-work questions, design/spec
# prompts, and prompts that already name the skills stay silent.
#
# Gated by ORCH_HOOK_PROFILE: skipped under minimal.
# Disabled if ORCH_DISABLED_HOOKS contains "orch-skill-nudge".
# Fail-open: any internal error → exit 0; this hook can never block a prompt.
# Bash 3.2 compatible. No jq.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-skill-nudge,"* ]]; then
  exit 0
fi
if [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Read the hook event JSON from stdin. Guarded on a non-tty stdin: run
# interactively without a redirect, a bare `cat` blocks forever. A hook that
# can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# Decode the prompt out of the event. It must be JSON-DECODED, not grepped —
# a grepped value keeps its escapes, so `\n` stays two word characters and
# kills every \b anchor below (see orch-research-gate.sh for the measured
# failure). The grep path is the degraded fallback for a python3-less
# environment: line-one-only, but not wrong.
JSON_LIB="${SCRIPT_DIR}/../lib/orch-json.sh"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${JSON_LIB}" ]] && source "${JSON_LIB}"

PROMPT=""
declare -f orch_json_field >/dev/null 2>&1 && PROMPT=$(orch_json_field "${INPUT}" prompt)
if [[ -z "${PROMPT}" ]]; then
  PROMPT=$(printf '%s' "${INPUT}" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
           | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//' \
           | head -1)
fi

if [[ -z "${PROMPT}" ]]; then
  exit 0
fi

# Slash commands are addressed to the command system, not bug reports.
# Judged on the FIRST non-empty line only: a line-based grep silenced any bug
# report that merely contained a pasted absolute path on a later line. And only
# COMMAND-SHAPED first lines count: a slash followed by a single word token
# (no further '/' or '.' inside it, e.g. /help, /llm-orchestrator:review). A
# bug report whose first line is a pasted absolute path ("/Users/me/data.csv")
# is not a command and must keep firing.
FIRST_LINE=$(printf '%s\n' "${PROMPT}" | grep -m1 -v '^[[:space:]]*$' || true)
if printf '%s' "${FIRST_LINE}" | grep -qE '^[[:space:]]*/[A-Za-z0-9:_-]+([[:space:]]|$)'; then
  exit 0
fi

# Normalize to lowercase for matching (bash 3.2 compatible).
LOWER=$(printf '%s' "${PROMPT}" | tr '[:upper:]' '[:lower:]')

# Prompt already names the skills → the nudge is redundant noise.
if printf '%s' "${LOWER}" | grep -qE 'systematic[- ]debugging|test[- ]driven[- ]development'; then
  exit 0
fi

matches() { printf '%s' "${LOWER}" | grep -qE "$1"; }

# --- high-precision bug-shape detection -----------------------------------
# Each arm is an imperative-bug shape, not a topic mention. Word-boundary,
# case-insensitive (via LOWER). Ordered cheap-to-expensive; first hit wins.
fire=0
if matches '\bfix(es|ing)?\b[[:space:]]+(the|this|it|that|my|our)\b'; then
  fire=1   # "fix it fast", "fix the login flow" — imperative; "fixed the" is a
           # completed action being reported, not a request, so no past tense here
elif matches '\bfix(es|ed|ing)?\b' && matches '\bbugs?\b'; then
  fire=1   # fix … bug, bug … fix — any order ("fixtures" must not count as fix)
elif matches '\burgent\b' && matches '\bfix(es|ed|ing)?\b'; then
  fire=1   # URGENT + fix
elif matches '\bbroken\b'; then
  fire=1
elif matches '\bfail(s|ing|ed|ure)?\b' && matches '\btests?\b|\btest_|_tests?\b|\bsuite\b|\bbuild\b|\bci\b|\bchecks?\b'; then
  fire=1   # failing/fails + test/build/suite, any order ("test_config.py is
           # failing" via \btest_; \btests?\b is anchored both sides so
           # "testimony" is not a test)
elif matches "\bstill\b[^.?!]*\b(fail(s|ing|ed)?|broken|crash(es|ed|ing)?|errors?[[:space:]]+out|error(ed|ing)( out)?|not working|doesn'?t work)\b"; then
  fire=1   # re-report: "you fixed it? … still fails" — a past-tense fix being
           # reported as NOT holding is a live bug, unlike a completed "fixed
           # the …" report; \bstill\b + a failure word in the same sentence.
           # Bare "red"/"error(s)" are topic nouns ("still prefer red for the
           # warning color", "docs still describe the error codes") — only
           # verb-shaped error forms count here, and still+red needs a CI noun:
elif matches '\b(suite|build|ci|pipeline|checks?|tests?)\b[^.?!]*\bstill\b[^.?!]*\bred\b|\bstill\b[^.?!]*\bred\b[^.?!]*\b(suite|build|ci|pipeline|checks?|tests?)\b'; then
  fire=1   # "the suite is still red" / "still red on ci" — red as a CI state,
           # not a color preference
elif matches '\bcrash(es|ed|ing)?\b'; then
  fire=1
elif matches '\btraceback\b|\bstack[[:space:]]?trace\b|\bsegfault(s|ed|ing)?\b'; then
  fire=1
elif matches '\b(unhandled|uncaught)[[:space:]]+exceptions?\b'; then
  fire=1
elif matches '\b(throws?|threw|throwing|raises?|raised|raising|getting|hitting|hit)\b[^.?!]*\bexceptions?\b'; then
  fire=1   # "getting an exception when …" — exception as symptom, not topic
elif matches '\bregressions?\b' && matches '\bfail(s|ing|ed|ure)?\b|\bbroke(n)?\b|\bbreaks?\b|\bcrash(es|ed|ing)?\b|\berrors?\b|\bbugs?\b|\bsince\b'; then
  fire=1   # regression + failure context ("regression since v2.3" — since marks
           # was-working-now-isn't). Bare "regression" alone is a topic mention:
           # "add a regression test for the new feature" is a task, not a bug.
elif matches '\breturn(s|ed|ing)?\b[^.?!]*\b(but|should|instead[[:space:]]of)\b'; then
  fire=1   # "returns X but/should Y" shapes
fi

if (( fire == 0 )); then
  exit 0
fi

# Question-shaped prompts about how code works stay silent: a leading
# interrogative with no imperative fix verb and no hard failure evidence is
# curiosity, not a bug report ("what happens when the worker crashes?").
# "why is test_config.py failing?" still fires — a failing test is hard
# evidence and systematic-debugging is exactly the tool.
if matches '^[[:space:]]*(how|what|where|why|when|which|who|explain|describe)\b'; then
  if ! matches '\b(fix|debug|repair|resolve|patch|solve)' \
     && ! { matches '\bfail(s|ing|ed|ure)?\b' && matches '\btests?\b|\btest_|_tests?\b|\bsuite\b|\bbuild\b|\bci\b|\bchecks?\b'; } \
     && ! matches '\btraceback\b|\bstack[[:space:]]?trace\b|\b(unhandled|uncaught)[[:space:]]+exceptions?\b'; then
    exit 0
  fi
fi

MSG="This prompt is bug-shaped: invoke the systematic-debugging skill before proposing a fix, and test-driven-development for the covering test — check first, discard if it does not apply."

# Native shell JSON escape (matches the sibling UserPromptSubmit hooks).
json_escape() {
  local s
  s=$(cat)
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  printf '"%s"' "${s}"
}

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-skill-nudge]: would inject bug-shape skill nudge (%s chars) as UserPromptSubmit additionalContext\n' "${#MSG}" >&2
  exit 0
fi

ESCAPED=$(printf '%s' "${MSG}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
