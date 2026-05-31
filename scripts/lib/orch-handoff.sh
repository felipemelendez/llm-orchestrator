#!/usr/bin/env bash
# LLM Orchestrator — handoff helpers library.
#
# Context-fill estimation from a JSONL transcript. The handoff-nudge hook calls
# orch_handoff_total_tokens to decide when usage has crossed the floor; the
# window/percentage helpers are general utilities over the same parser.
#
# Sourced by hooks; NEVER executed directly; never calls exit.
#
# Public API:
#   orch_handoff_total_tokens  <transcript_path> [nth]   (used by the nudge hook)
#   orch_handoff_window_tokens                           (general helper)
#   orch_handoff_estimate_pct  <transcript_path>         (general helper)
#
# Bash 3.2 compatible. No python3 / jq dependency.

# Double-source guard — only define if not already loaded.
if ! declare -f orch_handoff_estimate_pct >/dev/null 2>&1; then

# ---------------------------------------------------------------------------
# _orch_handoff_sum_cache_creation <raw_value>
#
# Internal helper: given the raw text matched for cache_creation_input_tokens,
# extract and sum all integer leaf values.
#
# The field can be:
#   - a plain integer:  160000
#   - a nested object:  {"ephemeral":50000,"persistent":70000}  (any depth)
#
# In both cases this emits the sum.  Pure awk — no python3 / jq.
# ---------------------------------------------------------------------------
_orch_handoff_sum_cache_creation() {
  local raw="$1"
  # Strip surrounding whitespace.
  raw=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # If it starts with a digit (or optional minus), treat as a plain integer.
  case "$raw" in
    [0-9]*|-[0-9]*)
      printf '%s' "$raw"
      return 0
      ;;
  esac

  # Otherwise extract only the numeric VALUES (numbers after a colon) from the
  # object and sum them.  Using grep -oE ':[[:space:]]*[0-9]+' avoids capturing
  # digits that are embedded inside key names (e.g. ephemeral_5m, ephemeral_1h).
  printf '%s' "$raw" \
    | grep -oE ':[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+' \
    | awk '{s+=$1} END {print (NR>0 ? s : 0)}'
}

# ---------------------------------------------------------------------------
# _orch_handoff_tokens_from_line <usage_line>
#
# Internal: given one JSONL line that contains a "usage" block, sum
#   input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# and print the integer total. Prints nothing (return 1) if input_tokens
# cannot be parsed.
# ---------------------------------------------------------------------------
_orch_handoff_tokens_from_line() {
  local last_line="$1"

  # --- Extract input_tokens ------------------------------------------------
  local input_tokens
  input_tokens=$(printf '%s' "$last_line" \
    | grep -oE '"input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')

  if [[ -z "$input_tokens" ]]; then
    return 1
  fi

  # --- Extract cache_read_input_tokens (plain integer, may be absent) ------
  local cache_read
  cache_read=$(printf '%s' "$last_line" \
    | grep -oE '"cache_read_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')
  cache_read="${cache_read:-0}"

  # --- Extract cache_creation_input_tokens (integer OR nested object) ------
  local raw_creation=""
  local plain_creation
  plain_creation=$(printf '%s' "$last_line" \
    | grep -oE '"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')

  if [[ -n "$plain_creation" ]]; then
    raw_creation="$plain_creation"
  else
    raw_creation=$(printf '%s' "$last_line" | awk '
      {
        key = "\"cache_creation_input_tokens\""
        idx = index($0, key)
        if (idx == 0) { next }
        rest = substr($0, idx + length(key))
        sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
        if (substr(rest,1,1) == "{") {
          depth=0
          out=""
          for (i=1; i<=length(rest); i++) {
            c = substr(rest,i,1)
            out = out c
            if (c == "{") depth++
            if (c == "}") { depth--; if (depth==0) { print out; exit } }
          }
        }
      }
    ')
  fi

  local cache_creation=0
  if [[ -n "$raw_creation" ]]; then
    cache_creation=$(_orch_handoff_sum_cache_creation "$raw_creation")
    cache_creation="${cache_creation:-0}"
  fi

  awk -v inp="$input_tokens" -v cr="$cache_read" -v cc="$cache_creation" \
    'BEGIN { print (inp + cr + cc) }'
}

# ---------------------------------------------------------------------------
# orch_handoff_total_tokens <transcript_path> [nth]
#
# Prints the total context tokens (input + cache_read + cache_creation) from
# the Nth-from-last non-synthetic usage-bearing line (nth=1 is the most recent,
# the default). Synthetic all-zero usage lines are skipped. Prints "unknown"
# (exit 0) on any failure or when fewer than nth such lines exist — advisory
# path only.
# ---------------------------------------------------------------------------
orch_handoff_total_tokens() {
  local transcript_path="$1"
  local nth="${2:-1}"

  if [[ -z "$transcript_path" ]] || [[ ! -f "$transcript_path" ]]; then
    printf 'unknown\n'
    return 0
  fi
  if ! [[ "$nth" =~ ^[0-9]+$ ]] || [[ "$nth" -lt 1 ]]; then
    nth=1
  fi

  # Bounded tail read (constant cost regardless of transcript size).
  #
  # Skip SYNTHETIC usage lines, where "synthetic" means the whole usage block is
  # zero (input + cache_read + cache_creation == 0) — interrupts / "<synthetic>"
  # stop markers. Do NOT key on input_tokens==0 alone: a genuine assistant turn
  # whose entire prompt prefix was a cache hit legitimately reports
  # input_tokens:0 with a large cache_read (verified common on long runs). Such a
  # turn carries the real fill and must be counted; dropping it would undercount
  # or, when the tail is all cache-hit turns, return "unknown" exactly when the
  # window is most full. So we compute each line's TOTAL and skip only zero-total
  # lines.
  #
  # Walk usage lines newest-first, skip zero-total lines, return the Nth surviving
  # total. The bounded tail keeps the line count (and thus iterations) small.
  local reversed
  reversed=$(tail -c "${ORCH_CONTEXT_TAIL_BYTES:-262144}" "$transcript_path" \
    | grep '"usage"' | grep '"input_tokens"' \
    | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }')

  if [[ -z "$reversed" ]]; then
    printf 'unknown\n'
    return 0
  fi

  local count=0 total ln
  while IFS= read -r ln; do
    [[ -z "$ln" ]] && continue
    total=$(_orch_handoff_tokens_from_line "$ln") || continue
    # Skip synthetic all-zero lines.
    [[ "$total" == "0" ]] && continue
    count=$((count + 1))
    if (( count == nth )); then
      printf '%s\n' "$total"
      return 0
    fi
  done <<< "$reversed"

  # Fewer than nth non-synthetic usage lines exist.
  printf 'unknown\n'
  return 0
}

# ---------------------------------------------------------------------------
# orch_handoff_window_tokens
#
# Prints the validated context-window size (ORCH_CONTEXT_WINDOW_TOKENS, default
# 1000000 = Opus / latest Claude Code model). Falls back to 1000000 if the env
# value is non-numeric or non-positive.
# ---------------------------------------------------------------------------
orch_handoff_window_tokens() {
  local window="${ORCH_CONTEXT_WINDOW_TOKENS:-1000000}"
  if ! [[ "$window" =~ ^[0-9]+$ ]] || ! [ "$window" -gt 0 ] 2>/dev/null; then
    window=1000000
  fi
  printf '%s\n' "$window"
}

# ---------------------------------------------------------------------------
# orch_handoff_estimate_pct <transcript_path>
#
# Finds the LAST assistant turn line in the JSONL transcript that contains a
# "usage" block with an "input_tokens" field, sums
#   input_tokens + cache_read_input_tokens + cache_creation_input_tokens,
# divides by the context window (orch_handoff_window_tokens), and prints the
# integer percentage to stdout.
#
# Prints "unknown" (exit 0) on any failure — advisory path only.
# ---------------------------------------------------------------------------
orch_handoff_estimate_pct() {
  local transcript_path="$1"

  local total
  total=$(orch_handoff_total_tokens "$transcript_path" 1)
  if [[ "$total" == "unknown" ]]; then
    printf 'unknown\n'
    return 0
  fi

  local window
  window=$(orch_handoff_window_tokens)

  awk -v total="$total" -v win="$window" \
    'BEGIN {
      if (win <= 0) { print "unknown"; exit }
      print int(total / win * 100)
    }'
  return 0
}


fi  # end double-source guard
