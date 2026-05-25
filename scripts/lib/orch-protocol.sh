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
# Finds the LAST object where role=="assistant" (or type=="assistant").
# Handles content as:
#   - a plain string: {"role":"assistant","content":"..."}
#   - an array of blocks: {"role":"assistant","content":[{"type":"text","text":"..."},...]}
#     (concatenates all text-type blocks)
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
            role = obj.get('role') or obj.get('type') or ''
            if role != 'assistant':
                continue
            content = obj.get('content', '')
            if isinstance(content, str):
                last_text = content
            elif isinstance(content, list):
                parts = [b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text']
                last_text = ''.join(parts)
except Exception:
    pass

if last_text is not None:
    print(last_text, end='')
PYEOF
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
# sub-block is present:
#   DONE              → requires a "Summary:" line
#   DONE_WITH_CONCERNS → requires a "Concerns:" line
#   BLOCKED           → requires a "Need:" line
#   NEEDS_CONTEXT     → requires an "Ask:" line
#
# Returns 0 (PASS) with a one-line reason, or 1 (FAIL) with reason.
# Bash 3.2 compatible.
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
  status_line=$(printf '%s\n' "$input" | grep -m1 '^Status:[[:space:]]*\(DONE\|DONE_WITH_CONCERNS\|BLOCKED\|NEEDS_CONTEXT\)' || true)

  if [[ -z "$status_line" ]]; then
    printf 'FAIL: no line-leading Status: with valid enum (DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)\n'
    return 1
  fi

  # Extract enum value.
  local enum
  enum=$(printf '%s\n' "$status_line" | sed 's/^Status:[[:space:]]*//' | sed 's/[[:space:]].*//')

  # Determine required sub-block header.
  local required_header
  case "$enum" in
    DONE)               required_header="Summary:" ;;
    DONE_WITH_CONCERNS) required_header="Concerns:" ;;
    BLOCKED)            required_header="Need:" ;;
    NEEDS_CONTEXT)      required_header="Ask:" ;;
    *)
      printf 'FAIL: unrecognized Status enum: %s\n' "$enum"
      return 1
      ;;
  esac

  # Check that the required sub-block header appears as a line start.
  local found_block
  found_block=$(printf '%s\n' "$input" | grep -m1 "^${required_header}" || true)

  if [[ -z "$found_block" ]]; then
    printf 'FAIL: Status: %s requires a "%s" line\n' "$enum" "$required_header"
    return 1
  fi

  printf 'PASS: Status: %s with %s is valid\n' "$enum" "$required_header"
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
