#!/usr/bin/env bash
# orch-protocol.sh — Concise Agent Protocol shape grader.
#
# Defines orch_grade_reply: reads a reply from stdin (or $1 file path),
# finds the first non-blank line, and validates the reply shape per the
# Concise Agent Protocol (concise-agent-protocol.md).
#
# Valid headers: Changed: Found: Blocked: Issues: Plan: Status:
# Extra rule for Changed:: a later line starting with "Verify:" must exist,
# OR the reply contains the literal text "no verification needed (cosmetic)".
#
# Returns 0 (PASS) or 1 (FAIL) with a one-line reason printed to stdout.
# Bash 3.2 compatible. Pure POSIX/bash + grep/sed; no external deps.
#
# Sourceable:
#   source scripts/lib/orch-protocol.sh
#   orch_grade_reply < reply.txt
#
# Runnable:
#   bash scripts/lib/orch-protocol.sh < reply.txt
#   bash scripts/lib/orch-protocol.sh reply.txt

ORCH_VALID_HEADERS='^(Changed|Found|Blocked|Issues|Plan|Status):'

# orch_extract_last_assistant_text <transcript_path>
#
# Parses a JSONL transcript (one JSON object per line) using python3.
# Finds the LAST assistant entry that carries non-empty text.
#
# REAL TRANSCRIPT SHAPE. Claude Code writes assistant entries as
#   {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[...]}}
# — the content is NESTED under "message". An earlier version read only the
# top-level "content" key, so on every real transcript it extracted nothing and
# every consumer bailed at its `[[ -n "${REPLY}" ]] || exit 0` guard. That
# silently disabled the protocol grader, the verify gate, and the retry cap's
# Stop path: they ran on every turn, found no reply, and passed. A gate that
# always passes looks exactly like a gate that never trips, which is why this
# survived. tests/test-protocol-hooks.sh now fixtures both shapes.
#
# Handles content as a plain string or an array of blocks (text blocks joined).
# Both the nested and top-level shapes are accepted; nested wins.
#
# SIDECHAIN ENTRIES ARE SKIPPED. Subagent turns are written into the same
# transcript with "isSidechain": true. Grading the controller's Stop event
# against a subagent's last message judges the wrong agent against the wrong
# contract.
#
#
# Prints the extracted text to stdout (with JSON escape sequences decoded).
# Prints nothing if no assistant message is found.
# Never fails (exits 0 always).
orch_extract_last_assistant_text() {
  local transcript_path="$1"
  python3 - "$transcript_path" <<'PYEOF' 2>/dev/null || true
import json, sys

path = sys.argv[1]
last_text = None

try:
    with open(path, 'r', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get('isSidechain') is True:
                continue
            msg = obj.get('message') if isinstance(obj.get('message'), dict) else None
            role = obj.get('role') or obj.get('type') or (msg.get('role') if msg else '') or ''
            if role != 'assistant':
                continue
            content = None
            if msg is not None and msg.get('content') is not None:
                content = msg.get('content')       # real transcripts
            else:
                content = obj.get('content', '')   # flat fixtures / other producers
            text = ''
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = ''.join(b.get('text', '') for b in content
                               if isinstance(b, dict) and b.get('type') == 'text')
            # The LAST assistant entry wins even when its text is empty (a pure
            # tool_use turn). Falling back to an earlier entry would grade the
            # PREVIOUS reply as if it were this one — bleed-through. Silence is
            # the safe answer: every consumer exits 0 on an empty reply.
            last_text = text
except Exception:
    pass

if last_text is not None:
    print(last_text, end='')
PYEOF
}

# orch_reply_from_hook_input <input_json> [transcript_path]
#
# THE HOOK STDIN, NOT THE TRANSCRIPT, CARRIES THE CURRENT TURN'S REPLY.
# Claude Code writes the transcript ASYNCHRONOUSLY — at Stop-hook time it may
# not yet contain the turn's final assistant message. Official hooks docs:
# "Hooks that need the final assistant text of the current turn should use
# `last_assistant_message` on Stop and SubagentStop instead of reading the
# transcript" and "The transcript file is written asynchronously and may lag."
# Scraping the transcript here graded a one-turn-STALE reply on tool-less
# turns (the gate warned about the PREVIOUS turn's claims — observed live) and
# an empty tool_use entry otherwise (silently blind).
#
# Parses last_assistant_message out of the hook's stdin JSON via
# orch_json_field — real JSON decoding, because the field is long text full of
# escaped quotes/newlines that grep cannot handle. If the field is present and
# non-empty, that IS the reply. If the field is PRESENT but empty (or null),
# that emptiness is a REAL observation — a pure tool_use turn ended with no
# final text — and the answer is an empty reply, NOT the transcript: falling
# back there graded the PREVIOUS turn's reply (executed proof: a stale
# transcript whose last entry was the prior turn's Changed: claim made the
# verify gate warn about the previous turn). Same sentinel semantics as
# subagent-stop.sh; every consumer exits 0 on an empty reply. Only when the
# field is ABSENT (an older harness, fixtures and tests that predate it) does
# orch_extract_last_assistant_text on the transcript apply.
#
# Fail-open by construction: any parse error, missing python3, or missing lib
# reads as field-absent and yields the transcript fallback (or nothing); it
# never crashes a hook.
orch_reply_from_hook_input() {
  local input_json="${1:-}" transcript_path="${2:-}" reply="" has_field=""
  if [[ -n "${input_json}" ]]; then
    if ! declare -f orch_json_field >/dev/null 2>&1; then
      local _json_lib
      _json_lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/orch-json.sh"
      # shellcheck source=scripts/lib/orch-json.sh
      [[ -f "${_json_lib}" ]] && source "${_json_lib}"
    fi
    if declare -f orch_json_field >/dev/null 2>&1; then
      reply=$(orch_json_field "${input_json}" last_assistant_message)
    fi
    if [[ -z "${reply}" ]] && declare -f orch_json_has_field >/dev/null 2>&1 \
       && orch_json_has_field "${input_json}" last_assistant_message; then
      has_field=1
    fi
  fi
  if [[ -n "${reply}" ]]; then
    printf '%s' "${reply}"
    return 0
  fi
  # Present-but-empty: return empty, no fallback (see header).
  [[ -n "${has_field}" ]] && return 0
  [[ -n "${transcript_path}" && -f "${transcript_path}" ]] || return 0
  orch_extract_last_assistant_text "${transcript_path}"
}

orch_grade_reply() {
  local input
  if [[ -n "${1:-}" && -f "$1" ]]; then
    input=$(cat "$1")
  else
    input=$(cat)
  fi

  # Find the first non-blank line.
  local first_line
  first_line=$(printf '%s\n' "$input" | grep -m1 -v '^[[:space:]]*$' || true)

  if [[ -z "$first_line" ]]; then
    printf 'FAIL: reply is empty or all blank\n'
    return 1
  fi

  # Check if first non-blank line matches a valid header.
  if ! printf '%s\n' "$first_line" | grep -qE "$ORCH_VALID_HEADERS"; then
    printf 'FAIL: first non-blank line is not a valid protocol header: %s\n' "$first_line"
    return 1
  fi

  # Extract the header word (everything before the colon).
  local header
  header=$(printf '%s\n' "$first_line" | sed 's/:.*//')

  # For Changed: replies, require Verify: line OR cosmetic exemption.
  # A Verify: line that appears inside a fenced code block (between ``` lines)
  # does NOT satisfy the requirement — only an outside-fence Verify: counts.
  if [[ "$header" == "Changed" ]]; then
    local has_cosmetic
    has_cosmetic=""
    case "$input" in
      *"no verification needed (cosmetic)"*) has_cosmetic="yes" ;;
    esac

    # Walk lines tracking fence state; look for Verify: outside any fence.
    # Use bash-native [[ == ]] glob matching — no subprocess per line.
    local has_verify_outside in_fence line_text
    has_verify_outside=""
    in_fence=0
    while IFS= read -r line_text; do
      # A line starting with ``` (optionally followed by a language tag) toggles fence state.
      if [[ "$line_text" == '```'* ]]; then
        if [[ $in_fence -eq 0 ]]; then
          in_fence=1
        else
          in_fence=0
        fi
        continue
      fi
      if [[ $in_fence -eq 0 && "$line_text" == 'Verify:'* ]]; then
        has_verify_outside="yes"
        break
      fi
    done <<< "$input"

    if [[ -z "$has_verify_outside" && -z "$has_cosmetic" ]]; then
      printf 'FAIL: Changed: reply missing Verify: line (or cosmetic exemption)\n'
      return 1
    fi
  fi

  printf 'PASS: %s: reply is valid\n' "$header"
  return 0
}

# orch_grade_status_block: validate a subagent Status: reply.
#
# Reads the reply from stdin. Finds a line whose first characters are
# "Status: <ENUM>" (line-anchored). Validates that the enum-implied
# sub-block(s) are present:
#   DONE              → requires a "Summary:" line
#   DONE_WITH_CONCERNS → requires a "Concerns:" line
#   BLOCKED           → requires a "Need:" line
#   NEEDS_CONTEXT     → requires an "Ask:" line
#   PARTIAL           → requires "Progress:" AND "Remaining:" lines
#
# Returns 0 (PASS) with a one-line reason, or 1 (FAIL) with reason.
# Bash 3.2 compatible.
# (Definition follows orch_strip_fenced / orch_has_section below.)

# orch_strip_fenced <text>
# Prints <text> with the contents of ``` fenced blocks removed.
#
# A protocol header quoted inside a code fence is an EXAMPLE, not a claim. The
# grader already honours this for Verify: (see below); the verify gate did not,
# so a `Found:` reply that quoted the protocol's own `Changed:` sample tripped
# the completion gate against itself. Strip once, then match.
orch_strip_fenced() {
  printf '%s\n' "$1" | awk '
    # ``` and ~~~ fences, plus 4-space/tab indented code blocks. A Changed:
    # sample quoted in any of those is an example; the gate used to fire on the
    # tilde and indented forms and warn a reply that changed nothing.
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    /^(    |\t)/ { next }
    { print }
  '
}

# orch_has_section <header-name> <text>
# True when <text> contains a line-leading "<header-name>:" section that has
# CONTENT — either on the same line, or on the following non-blank line(s).
#
# The protocol writes sub-sections both ways, and both are correct:
#     Verify: npm test → 142 passed
# and
#     Verify:
#     - `npm test` → 142 passed
# A same-line-only test (`^Verify:[[:space:]]*\S`) reads the second form as an
# empty Verify: and nags a reply that did everything right. Measured against a
# real transcript before this existed: the verify gate's first live firing was
# a false positive on exactly that shape.
#
# A following line that is itself a protocol header ends the section — so a
# bare "Verify:" directly above "Next:" is correctly treated as empty.
orch_has_section() {
  local header="$1" text="$2"
  printf '%s\n' "${text}" | awk -v h="${header}" '
    BEGIN { found = 0; insec = 0 }
    {
      line = $0
      # Accept `Verify:`, `**Verify:**`, `- Verify:`, `## Verify:` — all the
      # same section. Rejecting the decorated forms made the gate harsher on the
      # better-formatted reply.
      if (line ~ "^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}" h "[*_]{0,2}:") {
        rest = line
        sub("^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}" h "[*_]{0,2}:[*_]{0,2}[[:space:]]*", "", rest)
        if (rest ~ /[^[:space:]]/) { found = 1; exit }
        insec = 1
        next
      }
      if (insec) {
        if (line ~ /^[[:space:]]*$/) next
        # A peer sub-section ends this one. Narrowing this list to top-level
        # shape headers removed a false accusation but bought a false ALL-CLEAR,
        # which is the worse direction: `Verify:` followed by `Next: ship it`
        # was accepted as evidence and the gate went silent on a reply that had
        # verified nothing. Peers end the section; the residual cost is that an
        # unusual `Verify:` / `Summary: <output>` reads as empty.
        if (line ~ "^[[:space:]]*(Changed|Found|Blocked|Issues|Plan|Status|Recommendation|Verify|Why|Next|Notes|Risks|Summary|Concerns|Need|Ask|Progress|Remaining):") { insec = 0; next }
        # A bare fence delimiter is formatting, not content: `Verify:` followed
        # by an empty ``` block is not evidence.
        if (line ~ /^[[:space:]]*(```|~~~)[[:space:]]*[A-Za-z0-9_-]*[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*[-*][[:space:]]*$/) next
        found = 1; exit
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

orch_grade_status_block() {
  local input
  if [[ -n "${1:-}" && -f "$1" ]]; then
    input=$(cat "$1")
  else
    input=$(cat)
  fi

  # Find a line-leading Status: with a valid enum value.
  # Must start at column 0 (^Status:).
  local status_line
  status_line=$(printf '%s\n' "$input" | grep -m1 '^Status:[[:space:]]*\(DONE\|DONE_WITH_CONCERNS\|BLOCKED\|NEEDS_CONTEXT\|PARTIAL\)' || true)

  if [[ -z "$status_line" ]]; then
    printf 'FAIL: no line-leading Status: with valid enum (DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT|PARTIAL)\n'
    return 1
  fi

  # Extract enum value.
  local enum
  enum=$(printf '%s\n' "$status_line" | sed 's/^Status:[[:space:]]*//' | sed 's/[[:space:]].*//')

  # Determine required sub-block header(s) — space-separated list.
  # DONE and DONE_WITH_CONCERNS are completion claims, so they carry the
  # verification burden: the implementer contract (agents/orch-implementer.md)
  # requires a Verify: block with a real command and its real output. This
  # grader used to require only Summary:/Concerns:, which is why a DONE with no
  # Verify: at all passed deterministically and had to be caught by an LLM
  # validator on every implementer return. Deterministic, free, and earlier.
  local required_headers
  case "$enum" in
    DONE)               required_headers="Summary: Verify:" ;;
    DONE_WITH_CONCERNS) required_headers="Concerns: Verify:" ;;
    BLOCKED)            required_headers="Need:" ;;
    NEEDS_CONTEXT)      required_headers="Ask:" ;;
    PARTIAL)            required_headers="Progress: Remaining:" ;;
    *)
      printf 'FAIL: unrecognized Status enum: %s\n' "$enum"
      return 1
      ;;
  esac

  # Every required sub-block must be present AND carry content — on its own
  # line or the line below (orch_has_section). A bare "Verify:" with nothing
  # under it is not evidence.
  local required_header
  for required_header in $required_headers; do
    if ! orch_has_section "${required_header%:}" "$input"; then
      printf 'FAIL: Status: %s requires a "%s" line with content\n' "$enum" "$required_header"
      return 1
    fi
  done

  printf 'PASS: Status: %s with %s is valid\n' "$enum" "$required_headers"
  return 0
}

# When run directly (not sourced), call orch_grade_reply with $1 if provided.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -n "${1:-}" ]]; then
    orch_grade_reply "$1"
  else
    orch_grade_reply
  fi
fi
