#!/usr/bin/env bash
# LLM Orchestrator skill + command + agent validator.
#
# Skills:
#   - frontmatter has name + description
#   - directory name matches frontmatter name
#   - description starts with "Use when" OR "You MUST" (imperative-force form)
#   - SKILL.md is <= 250 lines
#   - no 4+ consecutive ALL-CAPS words outside code fences
#   - relative file references that look like paths resolve
#
# Commands:
#   - frontmatter description present
#   - "Invoke the X skill" references resolve to a real skills/X/SKILL.md
#
# Agents:
#   - frontmatter has name + description
#   - filename matches frontmatter name
#   - model is one of haiku|sonnet|opus|fable|inherit or a full id (if present)
#   - effort is one of low|medium|high|xhigh|max (if present)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
checked_skills=0
checked_commands=0
checked_agents=0

# Existing skill names (used to validate command references). Bash 3.2 compatible.
skill_names=()
while IFS= read -r line; do
  skill_names+=("$line")
done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)

# Skills
while IFS= read -r dir; do
  name=$(basename "$dir")
  file="$dir/SKILL.md"

  if [[ ! -f "$file" ]]; then
    echo "FAIL: $dir is missing SKILL.md"
    fail=1
    continue
  fi

  fm_name=$(awk '/^name:/ {print $2; exit}' "$file" | tr -d '\r')
  fm_desc=$(awk '/^description:/ {sub(/^description:[ ]*/,""); print; exit}' "$file" | tr -d '\r')
  lines=$(wc -l < "$file" | tr -d ' ')

  if [[ "$fm_name" != "$name" ]]; then
    echo "FAIL: $file frontmatter name='$fm_name' but directory='$name'"
    fail=1
  fi

  if [[ -z "$fm_desc" ]]; then
    echo "FAIL: $file missing description"
    fail=1
  elif [[ "$fm_desc" != Use\ when* && "$fm_desc" != You\ MUST* ]]; then
    echo "FAIL: $file description must start with 'Use when' or 'You MUST' (got: ${fm_desc:0:40}...)"
    fail=1
  fi

  if (( lines > 250 )); then
    echo "FAIL: $file is $lines lines (limit 250)"
    fail=1
  fi

  # Shouting check — skip inside code fences only. The skills no longer use
  # <EXTREMELY-IMPORTANT> directive blocks (house style is plain imperative
  # voice), so there is no shouting carveout to honour.
  awk '
    /^```/ { fence = !fence; next }
    fence { next }
    {
      n = split($0, words, /[[:space:]]+/);
      run = 0; max = 0
      for (i=1; i<=n; i++) {
        if (words[i] ~ /^[A-Z]{2,}$/) { run++; if (run > max) max = run }
        else { run = 0 }
      }
      if (max >= 4) { print FILENAME ":" NR ": shouting (" $0 ")"; exitcode = 1 }
    }
    END { exit exitcode+0 }
  ' "$file" >&2 || { fail=1; }

  # Validate templates/ references resolve
  while IFS= read -r ref; do
    if [[ -n "$ref" && ! -f "$ROOT/$ref" ]]; then
      echo "FAIL: $file references missing file: $ref"
      fail=1
    fi
  done < <(grep -oE 'templates/[a-z0-9-]+\.md' "$file" | sort -u)

  checked_skills=$((checked_skills+1))
done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d | sort)

# Required-section contract: handing-off-to-fresh-context
_handoff_file="$ROOT/skills/handing-off-to-fresh-context/SKILL.md"
if [[ -f "$_handoff_file" ]]; then
  for _section in "When to use" "When NOT to use" "Steps" "Output shape" "Anti-patterns"; do
    if ! grep -qF "## ${_section}" "$_handoff_file"; then
      echo "FAIL: $_handoff_file missing required section: ## ${_section}"
      fail=1
    fi
  done
fi

# Commands
while IFS= read -r file; do
  fm_desc=$(awk '/^description:/ {sub(/^description:[ ]*/,""); print; exit}' "$file" | tr -d '\r')
  if [[ -z "$fm_desc" ]]; then
    echo "FAIL: $file missing description"
    fail=1
  fi

  # Skill references in command bodies must resolve to a real skills/<name>/.
  # Only tokens in an explicit skill-reference CONTEXT are checked — "Invoke/Use
  # [the] `X`" or "`X` skill" — so a dangling reference IS caught (we assert
  # membership against the real skill list, NOT a pre-filtered known set; the
  # latter would make the check tautological and unable to flag anything).
  while IFS= read -r skill_ref; do
    [[ -z "$skill_ref" ]] && continue
    found=0
    for s in "${skill_names[@]+"${skill_names[@]}"}"; do
      if [[ "$s" == "$skill_ref" ]]; then found=1; break; fi
    done
    if (( found == 0 )); then
      echo "FAIL: $file references unknown skill: $skill_ref"
      fail=1
    fi
  done < <( { grep -oE '([Ii]nvoke|[Uu]se)( the)? `[a-z][a-z0-9-]+`' "$file";
              grep -oE '`[a-z][a-z0-9-]+` skill' "$file"; } \
            | grep -oE '`[a-z][a-z0-9-]+`' \
            | tr -d '`' \
            | sort -u)

  checked_commands=$((checked_commands+1))
done < <(find "$ROOT/commands" -maxdepth 1 -name '*.md' | sort)

# Agents (optional dir)
if [[ -d "$ROOT/agents" ]]; then
  while IFS= read -r file; do
    name_field=$(basename "$file" .md)
    fm_name=$(awk '/^name:/ {print $2; exit}' "$file" | tr -d '\r')
    fm_desc=$(awk '/^description:/ {sub(/^description:[ ]*/,""); print; exit}' "$file" | tr -d '\r')
    fm_model=$(awk '/^model:/ {print $2; exit}' "$file" | tr -d '\r')

    if [[ "$fm_name" != "$name_field" ]]; then
      echo "FAIL: $file frontmatter name='$fm_name' but filename='$name_field'"
      fail=1
    fi
    if [[ -z "$fm_desc" ]]; then
      echo "FAIL: $file missing description"
      fail=1
    fi
    fm_effort=$(awk '/^effort:/ {print $2; exit}' "$file" | tr -d '\r')
    if [[ -n "$fm_effort" && ! "$fm_effort" =~ ^(low|medium|high|xhigh|max)$ ]]; then
      echo "FAIL: $file effort='$fm_effort' not in low|medium|high|xhigh|max"
      fail=1
    fi
    fm_maxturns=$(awk '/^maxTurns:/ {print $2; exit}' "$file" | tr -d '\r')
    if [[ -n "$fm_maxturns" && ! "$fm_maxturns" =~ ^[1-9][0-9]*$ ]]; then
      echo "FAIL: $file maxTurns='$fm_maxturns' is not a positive integer"
      fail=1
    fi
    # The implementer must NOT carry maxTurns: its .orch-active mutex is
    # released by a voluntary final-turn rmdir, and a hard cap can strand it
    # (the reaper mitigates but does not license the cap; maxTurns may also
    # reset on SendMessage resume, so it is not a real bound).
    if [[ "$(basename "$file")" == "orch-implementer.md" && -n "$fm_maxturns" ]]; then
      echo "FAIL: orch-implementer.md must not set maxTurns (strands the writer mutex on cap)"
      fail=1
    fi
    if [[ -n "$fm_model" && ! "$fm_model" =~ ^(haiku|sonnet|opus|fable|inherit|claude-[a-z0-9.-]+)$ ]]; then
      echo "FAIL: $file model='$fm_model' not in haiku|sonnet|opus|fable|inherit|<full-id>"
      fail=1
    fi
    checked_agents=$((checked_agents+1))
  done < <(find "$ROOT/agents" -maxdepth 1 -name '*.md' | sort)
fi

if (( fail == 0 )); then
  echo "OK: $checked_skills skills, $checked_commands commands, $checked_agents agents"
else
  echo "FAILED"
  exit 1
fi
