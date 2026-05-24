#!/usr/bin/env bash
# LLM Orchestrator statusline.
# Reads the JSON status payload from stdin and prints a one-line statusline.
# Pieces shown: model, hook profile, active plan (if any), in-flight task,
# memory load status. Kept short so it doesn't wrap.

set -uo pipefail

INPUT=$(cat || true)

# Extract fields without jq.
field() {
  printf '%s' "${INPUT}" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

MODEL=$(field 'display_name')
[[ -z "${MODEL}" ]] && MODEL='?'

PROFILE="${ORCH_HOOK_PROFILE:-standard}"

# Active plan: most recent file in docs/llm-orchestrator/plans/
PLAN=""
if [[ -d docs/llm-orchestrator/plans ]]; then
  PLAN=$(ls -1t docs/llm-orchestrator/plans/*.md 2>/dev/null | head -1 | xargs basename 2>/dev/null || true)
fi

# Memory: count facts in this project (rough)
HASH=""
if command -v shasum >/dev/null 2>&1; then
  HASHER=shasum
elif command -v sha1sum >/dev/null 2>&1; then
  HASHER=sha1sum
fi
if [[ -n "${HASHER:-}" ]]; then
  REMOTE=$(git config --get remote.origin.url 2>/dev/null || true)
  if [[ -n "${REMOTE}" ]]; then
    HASH=$(printf '%s' "${REMOTE}" | ${HASHER} | cut -c1-12)
  fi
fi
MEM=""
if [[ -n "${HASH}" ]]; then
  MEM_FILE="${ORCH_HOME:-${HOME}/.llm-orchestrator}/memory/${HASH}.md"
  if [[ -f "${MEM_FILE}" ]]; then
    MEM_LINES=$(grep -c '^- ' "${MEM_FILE}" 2>/dev/null || echo 0)
    MEM=" mem:${MEM_LINES}"
  fi
fi

# Compose: model · profile · plan · memory
# Multi-char IFS only uses the first char for ${arr[*]} joining (bash limitation),
# so we build the string by hand with a literal separator.
SEP=" · "
LINE="${MODEL}${SEP}prof:${PROFILE}"
[[ -n "${PLAN}" ]] && LINE+="${SEP}plan:${PLAN%.md}"
[[ -n "${MEM}" ]] && LINE+="${SEP}${MEM# }"

printf '%s\n' "${LINE}"
