#!/usr/bin/env bash
# LLM Orchestrator — handoff helpers library.
#
# Provides context-fill estimation, handoff-document body hashing,
# revision counting, and no-op detection.
#
# Sourced by hooks and commands that prepare or inspect handoff documents.
# NEVER executed directly; never calls exit.
#
# Public API:
#   orch_handoff_estimate_pct <transcript_path>
#   orch_handoff_body_hash    <file>
#   orch_handoff_next_revision <file>
#   orch_handoff_is_noop      <file>
#
# Bash 3.2 compatible. No python3 / jq dependency.

# Double-source guard — only define if not already loaded.
if ! declare -f orch_handoff_estimate_pct >/dev/null 2>&1; then

# Resolve paths relative to this file.
_HANDOFF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source sibling library for orch_sha1_of if not already loaded.
if ! declare -f orch_sha1_of >/dev/null 2>&1; then
  # shellcheck source=orch-project.sh
  source "${_HANDOFF_LIB_DIR}/orch-project.sh"
fi

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
# orch_handoff_estimate_pct <transcript_path>
#
# Finds the LAST assistant turn line in the JSONL transcript that contains a
# "usage" block with an "input_tokens" field.  Sums:
#   input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# divides by ORCH_CONTEXT_WINDOW_TOKENS (default 1000000, Opus / latest Claude Code model), and prints the
# integer percentage to stdout.
#
# Prints "unknown" (exit 0) on any failure — advisory path only.
# ---------------------------------------------------------------------------
orch_handoff_estimate_pct() {
  local transcript_path="$1"

  # --- Validation ----------------------------------------------------------
  if [[ -z "$transcript_path" ]]; then
    printf 'orch_handoff_estimate_pct: missing transcript_path argument\n' >&2
    printf 'unknown\n'
    return 0
  fi

  if [[ ! -f "$transcript_path" ]]; then
    printf 'orch_handoff_estimate_pct: file not found: %s\n' "$transcript_path" >&2
    printf 'unknown\n'
    return 0
  fi

  # Estimates context fill for whatever transcript_path the harness provides
  # (for UserPromptSubmit/PreCompact that is the main session transcript).

  # --- Find the last usage-bearing line via bounded tail (constant cost) ---
  # Read only the last 256 KB to bound cost regardless of transcript size.
  # Transcripts are one JSON object per line; the most recent usage line is
  # near the end, so 256 KB reliably contains it. A partial first line from
  # the cut simply won't match grep — harmless.
  local last_line
  last_line=$(tail -c "${ORCH_CONTEXT_TAIL_BYTES:-262144}" "$transcript_path" \
    | grep '"usage"' | grep '"input_tokens"' | tail -1)

  if [[ -z "$last_line" ]]; then
    printf 'orch_handoff_estimate_pct: no usage line found in %s\n' "$transcript_path" >&2
    printf 'unknown\n'
    return 0
  fi

  # --- Extract input_tokens ------------------------------------------------
  # Match: "input_tokens": <number>
  local input_tokens
  input_tokens=$(printf '%s' "$last_line" \
    | grep -oE '"input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')

  if [[ -z "$input_tokens" ]]; then
    printf 'orch_handoff_estimate_pct: could not parse input_tokens\n' >&2
    printf 'unknown\n'
    return 0
  fi

  # --- Extract cache_read_input_tokens (plain integer, may be absent) ------
  local cache_read
  cache_read=$(printf '%s' "$last_line" \
    | grep -oE '"cache_read_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')
  cache_read="${cache_read:-0}"

  # --- Extract cache_creation_input_tokens (integer OR nested object) ------
  # We need to capture either a plain integer or a {...} block.
  # Strategy: cut everything after the key, then grab the first integer or
  # the first {…} block.
  local raw_creation=""
  # First try plain integer form: "cache_creation_input_tokens": 12345
  local plain_creation
  plain_creation=$(printf '%s' "$last_line" \
    | grep -oE '"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$')

  if [[ -n "$plain_creation" ]]; then
    raw_creation="$plain_creation"
  else
    # Try object form: "cache_creation_input_tokens": {...}
    # Extract everything from the key to the matching closing brace using awk.
    raw_creation=$(printf '%s' "$last_line" | awk '
      {
        key = "\"cache_creation_input_tokens\""
        idx = index($0, key)
        if (idx == 0) { next }
        rest = substr($0, idx + length(key))
        # skip whitespace and colon
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

  # --- Compute percentage --------------------------------------------------
  # Validate window: must be a positive integer; fall back to 1000000 if not.
  local window="${ORCH_CONTEXT_WINDOW_TOKENS:-1000000}"
  if ! [[ "$window" =~ ^[0-9]+$ ]] || ! [ "$window" -gt 0 ] 2>/dev/null; then
    window=1000000
  fi

  local pct
  pct=$(awk -v inp="$input_tokens" \
             -v cr="$cache_read" \
             -v cc="$cache_creation" \
             -v win="$window" \
    'BEGIN {
      total = inp + cr + cc
      if (win <= 0) { print "unknown"; exit }
      pct = int(total / win * 100)
      print pct
    }')

  printf '%s\n' "$pct"
  return 0
}

# ---------------------------------------------------------------------------
# _orch_handoff_strip_frontmatter
#
# Internal: reads stdin, strips the YAML frontmatter block (first --- line
# through the closing --- line inclusive) and prints the remainder.
#
# ONLY strips frontmatter when:
#   - Line 1 is exactly "---"
#   - AND a later "^---$" closing fence exists in the file
# If line 1 is "---" but NO closing fence is found (e.g. write interrupted
# mid-regeneration), the file is treated as having NO frontmatter and emitted
# unchanged — prevents an empty body hash on unterminated frontmatter.
# Markdown horizontal rules / diff "---" inside a properly-terminated body
# are preserved (only the leading fenced pair is removed).
# Pure awk — bash 3.2 compatible.
# ---------------------------------------------------------------------------
_orch_handoff_strip_frontmatter() {
  awk '
    BEGIN { collecting=0; in_fm=0; closed=0; first_line=1 }
    # Buffer all lines so we can decide after reading.
    { lines[NR] = $0 }
    END {
      # Determine whether line 1 is "---" and a closing fence exists.
      has_fm = 0
      close_at = 0
      if (NR >= 1 && lines[1] ~ /^---[[:space:]]*$/) {
        for (i = 2; i <= NR; i++) {
          if (lines[i] ~ /^---[[:space:]]*$/) {
            has_fm = 1
            close_at = i
            break
          }
        }
      }
      if (has_fm) {
        # Print lines after the closing fence.
        for (i = close_at + 1; i <= NR; i++) print lines[i]
      } else {
        # No valid frontmatter (or no closing fence): emit all lines unchanged.
        for (i = 1; i <= NR; i++) print lines[i]
      }
    }
  '
}

# ---------------------------------------------------------------------------
# orch_handoff_body_hash <file>
#
# Strips YAML frontmatter then prints a 12-char SHA-1 of the body.
# Used for no-op detection (frontmatter always mutates; body is what matters).
# ---------------------------------------------------------------------------
orch_handoff_body_hash() {
  local file="$1"

  if [[ -z "$file" ]]; then
    printf 'orch_handoff_body_hash: missing file argument\n' >&2
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    printf 'orch_handoff_body_hash: file not found: %s\n' "$file" >&2
    return 1
  fi

  local body
  body=$(< "$file" _orch_handoff_strip_frontmatter)
  orch_sha1_of "$body"
}

# ---------------------------------------------------------------------------
# orch_handoff_next_revision <file>
#
# Reads the current revision: integer from the file's YAML frontmatter.
# Prints current+1.  Prints 1 if the file does not exist or has no revision:.
# ---------------------------------------------------------------------------
orch_handoff_next_revision() {
  local file="$1"

  if [[ -z "$file" ]]; then
    printf 'orch_handoff_next_revision: missing file argument\n' >&2
    return 1
  fi

  local current=0

  if [[ -f "$file" ]]; then
    local rev_line
    rev_line=$(grep -m1 '^revision:' "$file" 2>/dev/null || true)
    if [[ -n "$rev_line" ]]; then
      local rev_val
      rev_val=$(printf '%s' "$rev_line" | sed 's/^revision:[[:space:]]*//' | grep -oE '^[0-9]+' || true)
      if [[ -n "$rev_val" ]]; then
        current="$rev_val"
      fi
    fi
  fi

  printf '%d\n' $((current + 1))
}

# ---------------------------------------------------------------------------
# orch_handoff_is_noop <file>
#
# Compares the body hash of <file> (working tree) against the committed copy
# at HEAD.  Prints "noop" if identical, "changed" otherwise.
# Prints "changed" when there is no committed copy (new file or git error).
# ---------------------------------------------------------------------------
orch_handoff_is_noop() {
  local file="$1"

  if [[ -z "$file" ]]; then
    printf 'orch_handoff_is_noop: missing file argument\n' >&2
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    printf 'orch_handoff_is_noop: file not found: %s\n' "$file" >&2
    return 1
  fi

  # Compute working-tree body hash.
  local working_hash
  working_hash=$(orch_handoff_body_hash "$file" 2>/dev/null) || {
    printf 'changed\n'
    return 0
  }

  # Derive the path relative to the git root for git show.
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'changed\n'
    return 0
  }

  # Make the path relative to the repo root.
  local rel_path
  # Use parameter expansion to strip the leading repo_root + /.
  rel_path="${file#${repo_root}/}"
  # If stripping didn't change it (file might be given as relative already),
  # try a realpath-free approach: cd and get the git relative path.
  if [[ "$rel_path" == "$file" ]]; then
    rel_path=$(cd "$(dirname "$file")" 2>/dev/null && git ls-files --full-name "$(basename "$file")" 2>/dev/null || true)
    if [[ -z "$rel_path" ]]; then
      printf 'changed\n'
      return 0
    fi
  fi

  # Belt-and-suspenders: guard against a rel_path that is empty or starts with
  # a dash (git show would interpret it as a flag).  rel_path comes from git
  # ls-files so this is theoretically impossible, but cheap to check.
  if [[ -z "$rel_path" ]] || [[ "$rel_path" == -* ]]; then
    printf 'changed\n'
    return 0
  fi

  # Get the committed body at HEAD.
  local committed_body
  committed_body=$(git show "HEAD:${rel_path}" 2>/dev/null | _orch_handoff_strip_frontmatter) || {
    printf 'changed\n'
    return 0
  }

  # If git show returned empty output (file not in HEAD), treat as changed.
  if [[ -z "$committed_body" ]]; then
    # Distinguish: body genuinely empty vs file not found.
    git show "HEAD:${rel_path}" >/dev/null 2>&1 || {
      printf 'changed\n'
      return 0
    }
  fi

  local committed_hash
  committed_hash=$(orch_sha1_of "$committed_body")

  if [[ "$working_hash" == "$committed_hash" ]]; then
    printf 'noop\n'
  else
    printf 'changed\n'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# orch_handoff_bodies_match <file_a> <file_b>
#
# Compares the body hashes (frontmatter stripped) of two files.
# Prints "noop"    if the body hashes are equal.
# Prints "changed" if they differ or either file cannot be hashed.
# Returns 0 always (advisory — never fails the caller).
#
# Use this for within-session no-op detection where neither file has been
# committed yet (so orch_handoff_is_noop, which compares against git HEAD,
# would always report "changed").
# ---------------------------------------------------------------------------
orch_handoff_bodies_match() {
  local file_a="$1"
  local file_b="$2"

  if [[ -z "$file_a" || -z "$file_b" ]]; then
    printf 'orch_handoff_bodies_match: requires two file arguments\n' >&2
    printf 'changed\n'
    return 0
  fi

  local hash_a hash_b
  hash_a=$(orch_handoff_body_hash "$file_a" 2>/dev/null) || {
    printf 'changed\n'
    return 0
  }
  hash_b=$(orch_handoff_body_hash "$file_b" 2>/dev/null) || {
    printf 'changed\n'
    return 0
  }

  if [[ "$hash_a" == "$hash_b" ]]; then
    printf 'noop\n'
  else
    printf 'changed\n'
  fi
  return 0
}

fi  # end double-source guard
