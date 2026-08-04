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

# Frontmatter fields must come from the FIRST ---…--- block ONLY. These scans
# used to match `^name:`/`^description:` anywhere in the file, so a key deleted
# from the frontmatter was satisfied by a body line — and that masking was live,
# not theoretical: skills/writing-skills/SKILL.md's body carries literal
# `name:`/`description:` example lines. Emits nothing when line 1 is not `---`
# or the key is absent from the block.
fm_field() { # <file> <key>
  awk -v key="$2" '
    NR==1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { exit }
    substr($0, 1, length(key) + 1) == key ":" {
      v = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", v)
      print v
      exit
    }
  ' "$1" | tr -d '\r'
}

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

  # The file must OPEN with a frontmatter block. fm_field also scopes itself
  # to that block, so a body line starting with "name:" can no longer satisfy
  # the scans below.
  if [[ "$(head -1 "$file" | tr -d '\r')" != "---" ]]; then
    echo "FAIL: $file does not open with a --- frontmatter block"
    fail=1
  fi

  fm_name=$(fm_field "$file" name)
  fm_desc=$(fm_field "$file" description)
  lines=$(wc -l < "$file" | tr -d ' ')

  if [[ "$fm_name" != "$name" ]]; then
    echo "FAIL: $file frontmatter name='$fm_name' but directory='$name'"
    fail=1
  fi

  if [[ -z "$fm_desc" ]]; then
    echo "FAIL: $file missing description"
    fail=1
  # 'You MUST' was accepted here as an exemption, which put the ban in the prose
  # (writing-skills, CLAUDE.md) and the blessing in the enforcement. An
  # unbounded imperative in a description is what manufactures trigger
  # collisions — "ANY bug", "any feature", "before claiming any work" all fire
  # at once with no stated precedence. 'Use when X. Not for Y.' forces the
  # author to draw the boundary.
  elif [[ "$fm_desc" != Use\ when* ]]; then
    echo "FAIL: $file description must start with 'Use when' (got: ${fm_desc:0:40}...)"
    fail=1
  fi

  if (( lines > 250 )); then
    echo "FAIL: $file is $lines lines (limit 250)"
    fail=1
  fi

  # BODY WORD BUDGET — a RATCHET, not a target.
  #
  # The 250-line cap never fired on the inflation that actually happened: a
  # 2,232-word skill sat comfortably under it, because words, not lines, are
  # what the catalog inflated in. A skill may shrink freely; growing past its
  # recorded size fails, which forces the author to justify the growth by
  # editing this list in the same commit — where a reviewer sees it.
  #
  # These ceilings were RAISED back to the pre-compression sizes on 2026-08-04,
  # on measurement, and this is that justification.
  #
  # The 2026-08-03 pass cut the instructional layer 22%. A 200-run A/B on
  # tdd-under-pressure (explicit "don't spend time on tests" pressure, graded on
  # whether the bug was fixed AND a covering test written) measured:
  #
  #     ref:4f6815f (pre-compression)   76/100 then 68/100   pooled 144/200 = 72%
  #     post-compression                        56/100                        56%
  #     Fisher p = 0.0065
  #
  # Restoring only skills/test-driven-development/SKILL.md did NOT recover it —
  # the with arm measured 56/100 both before and after that restore, identically.
  # So the cause was elsewhere in the pass, and the whole instructional layer was
  # returned to the measured-better state rather than guessed at file by file.
  #
  # Lowering an entry after a real trim is expected and encouraged, but a trim is
  # now a claim about behaviour: re-measure before believing it. The budget cuts
  # narration; it never cuts facts, and deleting a fact to hit a number is a bug.
  body_words=$(awk '/^---$/{c++; next} c>=2' "$file" | wc -w | tr -d ' ')
  case "$name" in
    dispatching-subagents)         limit=2202  ;;
    using-orchestrator)            limit=1535  ;;
    dispatching-parallel-agents)   limit=1389  ;;
    requesting-code-review)        limit=1249  ;;
    test-driven-development)       limit=1247  ;;
    research-classifier)           limit=1094  ;;
    brainstorming)                 limit=1087  ;;
    writing-plans)                 limit=1068  ;;
    using-git-worktrees)           limit=1018  ;;
    managing-memory)               limit=1012  ;;
    using-workflows)               limit=981   ;;
    systematic-debugging)          limit=972   ;;
    verification-before-completion) limit=942   ;;
    executing-plans)               limit=903   ;;
    writing-skills)                limit=847   ;;
    finishing-a-branch)            limit=769   ;;
    receiving-code-review)         limit=664   ;;
    *)                              limit=500  ;;
  esac
  if (( body_words > limit )); then
    echo "FAIL: $file body is $body_words words (ceiling $limit)"
    echo "      Trim it, or raise the ceiling in tests/validate-skills.sh in this same commit and say why."
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
  fm_desc=$(fm_field "$file" description)
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
    fm_name=$(fm_field "$file" name)
    fm_desc=$(fm_field "$file" description)
    fm_model=$(fm_field "$file" model)

    if [[ "$fm_name" != "$name_field" ]]; then
      echo "FAIL: $file frontmatter name='$fm_name' but filename='$name_field'"
      fail=1
    fi
    if [[ -z "$fm_desc" ]]; then
      echo "FAIL: $file missing description"
      fail=1
    fi
    fm_effort=$(fm_field "$file" effort)
    if [[ -n "$fm_effort" && ! "$fm_effort" =~ ^(low|medium|high|xhigh|max)$ ]]; then
      echo "FAIL: $file effort='$fm_effort' not in low|medium|high|xhigh|max"
      fail=1
    fi
    fm_maxturns=$(fm_field "$file" maxTurns)
    if [[ -n "$fm_maxturns" && ! "$fm_maxturns" =~ ^[1-9][0-9]*$ ]]; then
      echo "FAIL: $file maxTurns='$fm_maxturns' is not a positive integer"
      fail=1
    fi
    # The implementer must NOT carry maxTurns: its .orch-active mutex is
    # released by a voluntary final-turn rmdir, and a hard cap can strand it
    # (the reaper mitigates but does not license the cap; maxTurns may also
    # reset on SendMessage resume, so it is not a real bound). That mutex
    # rationale is worktree-mode-only — shared-checkout mode takes no lock —
    # but the rule stays unconditional: the agent file cannot vary per
    # envelope, and any given dispatch may be worktree mode.
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

# The counts above are real but were compared to NOTHING: deleting seven skill
# directories still printed "OK: 11 skills, ..." and exited 0. The core roster
# is load-bearing — the routing table, hooks, and commands reference these by
# name — so each one's absence is a hard failure that names it. Adding a NEW
# skill needs no change here; deleting a core one must be deliberate (remove
# it from this list in the same commit, where a reviewer can see both).
REQUIRED_SKILLS="using-orchestrator brainstorming writing-plans executing-plans \
dispatching-subagents dispatching-parallel-agents test-driven-development \
systematic-debugging verification-before-completion requesting-code-review \
receiving-code-review using-git-worktrees finishing-a-branch writing-skills \
using-workflows research-classifier managing-memory handing-off-to-fresh-context"
for req in $REQUIRED_SKILLS; do
  if [[ ! -f "$ROOT/skills/$req/SKILL.md" ]]; then
    echo "FAIL: core skill missing: skills/$req/SKILL.md (deletion must be deliberate — update REQUIRED_SKILLS in the same commit)"
    fail=1
  fi
done

# The command catalogue tables rot the same way the counts did: AGENTS.md and
# docs/commands-guide.md are hand-maintained listings of commands/*.md, and by
# 2026-08 they had drifted to 13 and 11 of the 14 commands that exist — fixed by
# hand, which without this check they will need again. Every command file must
# have a `| `/llm-orchestrator:<name>`` table row in BOTH documents. Adding a
# command therefore forces its catalogue rows in the same commit.
for _cmd_file in "$ROOT"/commands/*.md; do
  [[ -f "$_cmd_file" ]] || continue
  _cmd="$(basename "$_cmd_file" .md)"
  for _doc in "$ROOT/AGENTS.md" "$ROOT/docs/commands-guide.md"; do
    if ! command grep -qE "^\| *\`/llm-orchestrator:${_cmd}\`" "$_doc"; then
      echo "FAIL: ${_doc#$ROOT/} catalogue table has no row for /llm-orchestrator:${_cmd} (commands/${_cmd}.md exists — the listing has rotted)"
      fail=1
    fi
  done
done

# Docs quote this script's own summary line as an example of a passing run, and a
# quoted count is a claim that rots the first time the catalogue changes — the
# same drift that let CI list its suites by hand and lose ten of them. Any doc
# reproducing the exact `OK: N skills, N commands, N agents` shape has to match
# what this run actually counted. Prose like "past ~40 skills" is untouched: the
# pattern is deliberately the literal output line, not any sentence with a number.
expected_line="OK: $checked_skills skills, $checked_commands commands, $checked_agents agents"
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  f="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
  quoted="$(printf '%s' "$hit" | sed -n 's/.*\(OK: [0-9]* skills, [0-9]* commands, [0-9]* agents\).*/\1/p')"
  if [[ -n "$quoted" && "$quoted" != "$expected_line" ]]; then
    echo "FAIL: $f:$ln quotes \"$quoted\" but this run counts \"$expected_line\""
    fail=1
  fi
done < <(command grep -rn --include='*.md' -e 'OK: [0-9]* skills, [0-9]* commands, [0-9]* agents' "$ROOT" 2>/dev/null \
         | command grep -v "$ROOT/docs/llm-orchestrator/" | command grep -v "$ROOT/CHANGELOG.md")

# The plugin version is quoted in prose, and a quoted version rots: manual-testing
# claimed 0.1.0 while the plugin shipped 0.6.0, and marketplace.json is a second
# copy that must agree with plugin.json or an install advertises the wrong build.
# One source of truth, checked against every copy.
PLUGIN_VERSION=$(python3 -c "import json;print(json.load(open('${ROOT}/.claude-plugin/plugin.json'))['version'])" 2>/dev/null)
if [[ -z "${PLUGIN_VERSION}" ]]; then
  echo "FAIL: cannot read version from .claude-plugin/plugin.json"
  fail=1
else
  MP_VERSION=$(python3 -c "
import json
d=json.load(open('${ROOT}/.claude-plugin/marketplace.json'))
print(d['plugins'][0].get('version',''))" 2>/dev/null)
  if [[ "${MP_VERSION}" != "${PLUGIN_VERSION}" ]]; then
    echo "FAIL: marketplace.json says '${MP_VERSION}' but plugin.json says '${PLUGIN_VERSION}'"
    fail=1
  fi
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    f="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
    quoted=$(printf '%s' "$hit" | sed -n 's/.*Version `\([0-9][0-9.]*\)`.*/\1/p')
    if [[ -n "$quoted" && "$quoted" != "${PLUGIN_VERSION}" ]]; then
      echo "FAIL: $f:$ln quotes Version \`${quoted}\` but plugin.json says ${PLUGIN_VERSION}"
      fail=1
    fi
  done < <(command grep -rn --include='*.md' -e 'Version `[0-9][0-9.]*`' "$ROOT" 2>/dev/null \
           | command grep -v "$ROOT/docs/llm-orchestrator/" | command grep -v "$ROOT/CHANGELOG.md" \
           | command grep -v "$ROOT/.claude/worktrees/")
fi

if (( fail == 0 )); then
  echo "OK: $checked_skills skills, $checked_commands commands, $checked_agents agents"
else
  echo "FAILED"
  exit 1
fi
