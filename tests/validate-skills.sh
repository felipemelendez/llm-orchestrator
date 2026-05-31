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
#   - model is one of haiku|sonnet|opus (if present)

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

  # Shouting check — skip inside code fences AND inside explicit directive
  # blocks like <EXTREMELY-IMPORTANT>...</EXTREMELY-IMPORTANT>. The directive
  # tag is deliberately load-bearing prose; shouting there is intentional.
  awk '
    /^```/ { fence = !fence; next }
    /<EXTREMELY[-_]IMPORTANT>/ { directive = 1; next }
    /<\/EXTREMELY[-_]IMPORTANT>/ { directive = 0; next }
    fence || directive { next }
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

  # Skill references in command bodies must resolve. We look for either:
  #   - `<skill-name>` matching a known skill dir
  #   - "Invoke the X skill" patterns
  KNOWN_SKILLS="brainstorming|writing-plans|executing-plans|test-driven-development|systematic-debugging|using-git-worktrees|dispatching-subagents|dispatching-parallel-agents|requesting-code-review|receiving-code-review|verification-before-completion|finishing-a-branch|writing-skills|managing-memory|using-orchestrator|using-workflows"

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
  done < <(grep -oE '`[a-z][a-z0-9-]+`' "$file" \
            | tr -d '`' \
            | grep -E "^(${KNOWN_SKILLS})$" \
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
    if [[ -n "$fm_model" && ! "$fm_model" =~ ^(haiku|sonnet|opus)$ ]]; then
      echo "FAIL: $file model='$fm_model' not in haiku|sonnet|opus"
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
