#!/usr/bin/env bash
# cadence-init.sh — turn the cadence on for one project: the law documents, the
# marked block, the deny rules, the git layer, and the lock over all of them.
#
# WHAT
#   cadence-init.sh [--root <dir>] [--config <cadence.json>] [--adopt] [--dry-run]
#
#   --root <dir>       the project to initialize (default: git toplevel of $PWD,
#                      else CLAUDE_PROJECT_DIR, else $PWD)
#   --config <file>    the cadence.json the user confirmed. Without it the
#                      detector's proposal is used as-is.
#   --adopt            the project already has its own laws. Changes the wording
#                      of the report and drops the "fill in the placeholders"
#                      reminder; it changes nothing about what is written,
#                      because nothing is ever overwritten either way.
#   --dry-run          print the plan and write nothing.
#
# WHY
#   Everything here is an install, and an install that clobbers is worse than no
#   install: a tool that overwrites a project's LAWS.md while arming the lock on
#   it has destroyed the one file the lock exists to protect. So every path is
#   `created` when absent and `kept` when present, and the only two paths a flag
#   can overwrite (the two git hooks and cadence.json) need ORCH_CADENCE_UNLOCK=1
#   in the environment, the same hatch the rest of the cadence uses.
#
#   ORDER MATTERS. A cadence project's protection covers LAWS.md, cadence.json,
#   LOCK.sha256, .claude/settings.json and .githooks/** from the moment
#   docs/llm-orchestrator/cadence.json exists with "enabled": true. So
#   cadence.json is written LAST, after every other file is in place, and the
#   manifest is written after that. An init that wrote the config first would be
#   refused by its own enforcement halfway through.
#
#   REFUSALS ARE A PREFLIGHT. Every condition that can stop this script is
#   checked before the first byte is written, so a refusal never leaves a
#   half-initialized project behind.
#
# EXIT CODES
#   0  the project is initialized (or the plan printed)
#   1  a refusal, or --lock failed to arm a project that had no manifest
#
# NOTES
#   python3 is needed only for the STRUCTURAL merge of an existing
#   .claude/settings.json and to normalize a --config file; a settings file is
#   JSON with the operator's own keys in it, and text-editing one is how a
#   settings file becomes a corrupted settings file. When there is none to merge,
#   this script needs no interpreter at all. ORCH_CADENCE_PYTHON points at
#   another one (or at a path that does not exist, to exercise the python-free
#   path).
#   This script never runs `git config`: routing a repo's hooks is the person's
#   decision, so the one-liner is printed, not executed.
#   Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.  # portable-ok

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REF_DIR="$SCRIPT_DIR/../references"
CHECK="$SCRIPT_DIR/orch-cadence-check.sh"

LAWS_REL='docs/llm-orchestrator/LAWS.md'
CFG_REL='docs/llm-orchestrator/cadence.json'
LOCK_REL='docs/llm-orchestrator/LOCK.sha256'
SETTINGS_REL='.claude/settings.json'
SEC_START='<!-- ORCH:LAWS:START -->'
SEC_END='<!-- ORCH:LAWS:END -->'
GITIGNORE_REL='.gitignore'
# The merge copies the operator's own settings file aside before rewriting it.
# That backup is theirs, not the project's: `git add -A` in the arming commit
# would otherwise commit a copy of their settings into the repository.
IGNORE_1='.claude/settings.json.bak'
IGNORE_2='.claude/settings.json.bak.*'
# A replaced ORCH:LAWS section leaves the same kind of backup beside AGENTS.md
# or CLAUDE.md. One glob each covers .bak and the .bak.N shapes.
IGNORE_3='AGENTS.md.bak*'
IGNORE_4='CLAUDE.md.bak*'

PY="${ORCH_CADENCE_PYTHON:-python3}"

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

OPT_ROOT=""; OPT_CONFIG=""; ADOPT=0; DRY=0

usage() {
  echo "usage: cadence-init.sh [--root <dir>] [--config <cadence.json>] [--adopt] [--dry-run]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)    shift; OPT_ROOT="${1:-}" ;;
    --config)  shift; OPT_CONFIG="${1:-}" ;;
    --adopt)   ADOPT=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ -n "$OPT_ROOT" ]; then
  ROOT_DIR="$OPT_ROOT"
else
  t=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$t" ] && [ -d "$t" ]; then ROOT_DIR="$t"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then ROOT_DIR="$CLAUDE_PROJECT_DIR"
  else ROOT_DIR="$PWD"; fi
fi
ROOT_DIR="${ROOT_DIR%/}"

have_py() { command -v "$PY" >/dev/null 2>&1 && "$PY" -c 'pass' >/dev/null 2>&1; }
unlocked() { [ "${ORCH_CADENCE_UNLOCK:-}" = "1" ]; }

# 0 until the first byte lands. A refusal that fires before it is set can say
# so, which is the difference between "stop, nothing happened" and "stop, and
# now go and work out what half-landed".
WROTE=0

refuse() { # <path-or-empty> <reason>
  if [ -n "$1" ]; then echo "refused $1: $2"; else echo "refused: $2"; fi
  [ "$WROTE" = "0" ] && echo "nothing was written"
  exit 1
}

# A typo in --root should not scaffold a project tree in a directory nobody
# meant to name: mkdir -p later would create the whole path without a word.
[ -d "$ROOT_DIR" ] || refuse "" "no such directory: $ROOT_DIR"
ROOT_PHYS=$(cd "$ROOT_DIR" && pwd -P) || refuse "" "cannot enter $ROOT_DIR"

# Hooks in a directory git never reads are enforcement that does not exist, and
# a hooks-path line printed there is an instruction that cannot be followed.
IS_GIT=0
git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1

# Where a write to <path> actually lands: the link chain followed to its end,
# then the containing directory resolved physically. The one-call GNU flag for
# this is not on BSD, so the chain is walked by hand.
phys_of() { # <path> -> absolute physical path, or non-zero
  local p="$1" t d b n=0
  while [ -L "$p" ] && [ "$n" -lt 32 ]; do
    t=$(readlink "$p") || return 1
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(dirname "$p")/$t" ;;
    esac
    n=$((n+1))
  done
  d=$(dirname "$p"); b=$(basename "$p")
  d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${d%/}" "$b"
}

# Where a write to <path> would LAND, whether or not the path exists yet: the
# nearest ancestor that is already there is resolved physically and the
# components that do not exist yet are re-appended. Testing the leaf alone tests
# nothing when the link that leaves the project is a directory two levels up.
land_of() { # <absolute path> -> absolute physical path, or non-zero
  local p="$1" rest="" base ph
  while [ ! -e "$p" ] && [ ! -L "$p" ] && [ "$p" != "/" ]; do
    base="${p##*/}"; p="${p%/*}"; [ -n "$p" ] || p="/"
    if [ -n "$rest" ]; then rest="$base/$rest"; else rest="$base"; fi
  done
  ph=$(phys_of "$p") || return 1
  if [ -n "$rest" ]; then printf '%s/%s\n' "${ph%/}" "$rest"; else printf '%s\n' "$ph"; fi
}

# A write to <path> can succeed when the path itself is writable, or — when it
# does not exist yet — when its nearest existing ancestor directory is.
can_write() { # <absolute path>
  local p="$1" d
  if [ -e "$p" ]; then [ -w "$p" ]; return $?; fi
  d=$(dirname "$p")
  while [ ! -e "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d=$(dirname "$d"); done
  [ -d "$d" ] && [ -w "$d" ] && [ -x "$d" ]
}

past() { # <verb> -> its past tense, for the report
  case "$1" in
    create)  echo created ;;
    keep)    echo kept ;;
    merge)   echo merged ;;
    replace) echo replaced ;;
    append)  echo appended ;;
    insert)  echo inserted ;;
    *)       echo "$1" ;;
  esac
}

emit() { # <verb> <path> [<suffix>]
  if [ "$DRY" = "1" ]; then printf 'would %s %s%s\n' "$1" "$2" "${3:-}"
  else printf '%s %s%s\n' "$(past "$1")" "$2" "${3:-}"; fi
}

# One line, printed and never written into the project: the deny rules are a
# permission layer over the agent's own tools, and whether they also reach a
# command the agent spawns depends on a setting this script does not own. It
# names both ways to turn that setting on, because a tip that says a second
# layer exists without saying how to reach it costs the reader the layer.
print_tip() {
  echo "tip: Claude Code's sandbox is optional; turn it on with /sandbox in a session or \"sandbox\": {\"enabled\": true} in .claude/settings.json, and the Edit(...) deny rules above also bind every subprocess (see docs/install.md, \"The lock's two layers\")"
}

# The block the cadence writes into AGENTS.md. It lives in templates/ in the
# plugin layout; the Codex install may drop a copy beside the skill's own
# references so a skill copied out of the plugin still carries it. The
# skill-local copy wins: it is the one that travels with these scripts.
BLOCK=""
for cand in "$REF_DIR/global-block.md" "$SCRIPT_DIR/../../../templates/cadence-global-block.md"; do
  if [ -f "$cand" ]; then
    # Normalized, because the refusal NAMES this path: a reader who has to
    # decide which of two installs won cannot do it from a ../../.. spelling.
    BLOCK="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
    break
  fi
done

# ---------- preflight ---------------------------------------------------------
# Nothing below this block writes; nothing above it does either.

for f in "$REF_DIR/laws.md" "$REF_DIR/handoff.md" "$REF_DIR/design-rulings.md" \
         "$REF_DIR/traps.md" "$REF_DIR/commit-msg"; do
  [ -f "$f" ] || refuse "" "the skill's references are incomplete — $f is missing"
done
[ -f "$CHECK" ] || refuse "" "orch-cadence-check.sh is not beside this script — the git layer would ship a dead hook"
[ -n "$BLOCK" ] || refuse "" "cadence-global-block.md was not found beside this script or in templates/"

AGENTS_F="$ROOT_DIR/AGENTS.md"
CLAUDE_F="$ROOT_DIR/CLAUDE.md"
SETTINGS_F="$ROOT_DIR/$SETTINGS_REL"
GITIGNORE_F="$ROOT_DIR/$GITIGNORE_REL"

# Every target this script can write, whether or not it exists yet. A path that
# resolves outside the project is a write into somebody else's file, made under
# a report that names a path inside this one — and the link that takes it there
# is as often a directory two levels up (docs/, .claude/, .githooks/) as the
# named file, so every target is resolved, not only the ones that are links.
for rel in AGENTS.md CLAUDE.md "$SETTINGS_REL" "$GITIGNORE_REL" "$LAWS_REL" \
           docs/llm-orchestrator/HANDOFF_TEMPLATE.md docs/llm-orchestrator/DESIGN_RULINGS.md \
           docs/llm-orchestrator/TRAPS.md "$CFG_REL" "$LOCK_REL" \
           .githooks/commit-msg .githooks/orch-cadence-check.sh; do
  t="$ROOT_PHYS/$rel"
  # An existing node that is not a regular file is a write that cannot succeed.
  # A directory refuses late, with half the project already on disk; a FIFO or a
  # socket does worse — the write blocks on a reader that never comes and the
  # run never returns at all. One arm covers directories, FIFOs, sockets and
  # devices alike.
  if [ -e "$t" ] && [ ! -f "$t" ]; then
    if [ -d "$t" ]; then tkind="a directory"; else tkind="a special file"; fi
    refuse "$rel" "$tkind is sitting at that path — move it aside, then re-run"
  fi
  ph=$(land_of "$t") || refuse "$rel" "it is a link whose target cannot be resolved"
  case "$ph" in
    "$ROOT_PHYS"/*) ;;
    *) refuse "$rel" "it is a link that leaves the project (it resolves to $ph) — writing through it would edit a file outside $ROOT_DIR" ;;
  esac
done
# CLAUDE.md importing AGENTS.md only works while they are two files. Linked or
# hard-linked together, the import line makes one file import itself.
PH_AGENTS=$(phys_of "$AGENTS_F" 2>/dev/null) || PH_AGENTS=""
PH_CLAUDE=$(phys_of "$CLAUDE_F" 2>/dev/null) || PH_CLAUDE=""
if [ -n "$PH_AGENTS" ] && [ "$PH_AGENTS" = "$PH_CLAUDE" ]; then
  refuse "CLAUDE.md" "it and AGENTS.md are the same file — the import would make that file import itself; separate them, then re-run"
fi
if [ -f "$AGENTS_F" ] && [ -f "$CLAUDE_F" ] && [ "$AGENTS_F" -ef "$CLAUDE_F" ]; then
  refuse "CLAUDE.md" "it and AGENTS.md are the same file — the import would make that file import itself; separate them, then re-run"
fi

# The manifest hashes the ORCH:LAWS section of AGENTS.md AND of CLAUDE.md, and
# --lock refuses a file with a second START marker, with a START and no END, or
# with an END and no START. Each of those is a refusal, and a refusal belongs
# here: left to the lock it fires with the whole project already written and
# cadence.json already on. Markers are COUNTED, because a file with two complete
# pairs has both of them present and is still not one section.
#
# THE SECTION, in five lines — the one definition the three readers owe:
#   1. the span is the first line containing START through the first line at or
#      after it containing END, inclusive; both may be the same line, and a
#      marker matches as a plain substring, so `<!-- see …START -->` is not one;
#   2. well-formed is the lock's terms: >1 START occurrence is duplicate, an END
#      with no START is orphan, a START with no END at or after it is
#      unterminated, none of either is "no section, may receive one";
#   3. `kept` is CONTENT equality, never marker position: the text strictly
#      between the two marker lines, every line's trailing whitespace stripped
#      (CR included, so a CRLF file is not refused for its line endings), must
#      equal the interior of the block THIS install resolved — and the refusal
#      names which file that was, because two installs can carry two of them;
#   4. the residual, and it is deliberate: a fence or a <pre> around the EXACT
#      block is kept, because the wrapper lines fall outside the marker pair —
#      the laws text is present byte for byte and the lock hashes the same span,
#      so the loss is rendering, not governance. The residual is read, never
#      written: the replacement refuses a file whose fences do not balance, in
#      the append path's own words, rather than write the block under an
#      unclosed opener that path would refuse to append into;
#   5. under ORCH_CADENCE_UNLOCK=1 a span that is not the block is REPLACED
#      whole, marker lines included, by the block, the file backed up first.
# Rules 1-2 are marker_rc's; rules 3-5 are section_is_block's and
# replace_section's. No reader consults a list of markdown code forms, so no
# such list can be missing one, and a sample beside a live block is still two
# STARTs (rule 2). Two readers hold copies of this — see the follow-up
# ticket: one section reader in a sourceable library shared by the check
# script and the init.
MARK_STARTS=0
marker_rc() { # <file> -> 0 fine (starts in MARK_STARTS), 2 duplicate, 3 unterminated, 4 orphan end
  local f="$1" ns ne ls le
  MARK_STARTS=0
  [ -f "$f" ] || return 0
  ns=$(grep -oF -- "$SEC_START" "$f" 2>/dev/null | wc -l | tr -d ' '); [ -n "$ns" ] || ns=0
  ne=$(grep -oF -- "$SEC_END"   "$f" 2>/dev/null | wc -l | tr -d ' '); [ -n "$ne" ] || ne=0
  MARK_STARTS="$ns"
  # The lock's verdicts, exactly: duplicate is more than one START; orphan end
  # is an END with no START at all; unterminated is a START with no END at or
  # after it. A second END below a complete pair changes no section the lock
  # would read, and it accepts that file — refusing it here would block a
  # project over a marker the message names and the file does not have.
  if [ "$ns" -gt 1 ]; then return 2; fi
  if [ "$ns" -eq 0 ]; then
    [ "$ne" -eq 0 ] && return 0
    return 4
  fi
  [ "$ne" -eq 0 ] && return 3
  ls=$(grep -nF -- "$SEC_START" "$f" | head -1 | cut -d: -f1)
  le=$(grep -nF -- "$SEC_END" "$f" | cut -d: -f1 | awk -v s="${ls:-0}" '$1 >= s { print; exit }')
  [ -n "$le" ] || return 3
  return 0
}

# THE SECTION READER. `kept` is a verdict about CONTENT, not about where the
# markers sit: a file is kept only when the text between its markers IS the
# block this install resolved. There is no list of markdown code forms here any
# more, so no form can be missing from a list that does not exist: a quoted,
# indented or <pre>-prefixed sample differs between the markers and is refused by
# the same test that refuses an older version of the block. A fence around the
# EXACT block is the stated residual of rule 4 — the fence lines fall outside the
# marker pair, the text is present byte for byte and the lock hashes the same
# span, so the loss is rendering, not governance.

# The first free backup path for <file>: <file>.bak, then .bak.1, .bak.2 …
# A replacement that overwrites an existing .bak destroys the very thing the
# first backup was made to keep.
backup_path() { # <absolute file> -> a path that does not exist yet
  local b="$1.bak" n=1
  while [ -e "$b" ]; do b="$1.bak.$n"; n=$((n+1)); done
  printf '%s\n' "$b"
}

SEC_L1=""; SEC_L2=""
section_span() { # <file> -> SEC_L1, SEC_L2; non-zero when there is no span
  local f="$1"
  SEC_L1=""; SEC_L2=""
  [ -f "$f" ] || return 1
  SEC_L1=$(grep -nF -- "$SEC_START" "$f" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$SEC_L1" ] || return 1
  SEC_L2=$(grep -nF -- "$SEC_END" "$f" 2>/dev/null | cut -d: -f1 \
             | awk -v s="$SEC_L1" '$1 >= s { print; exit }')
  [ -n "$SEC_L2" ] || { SEC_L2=""; return 1; }
  return 0
}

# The text strictly between the two marker lines, every line's trailing
# whitespace removed. [[:space:]] and not [[:blank:]]: the class has to include
# CR, or a CRLF file carrying the exact block is refused and then silently
# rewritten to LF by the replacement below.
section_interior() { # <file> <first line> <last line>
  awk -v a="$2" -v b="$3" 'NR > a && NR < b' "$1" | sed 's/[[:space:]]*$//'
}

# 0 when the file's span IS the block. The file's own span is left in SEC_L1/L2.
section_is_block() { # <file>
  section_span "$1" || return 1
  section_interior "$1" "$SEC_L1" "$SEC_L2" > "$TMPD/sec.have" 2>/dev/null || return 1
  cmp -s "$TMPD/sec.have" "$BLOCK_WANT"
}

# The unlock's one write into a marked file: the WHOLE span, marker lines
# included, becomes the block. Replacing only the interior would leave a quoted
# or indented sample's own marker lines as the boundary and put un-prefixed
# block text inside somebody's blockquote. The span is recomputed here rather
# than carried from the preflight, because CLAUDE.md may have gained its import
# line in between.
SECTION_REPLACED=0
replace_section() { # <file> <relative name>
  local f="$1" rel="$2" bak
  section_span "$f" || refuse "$rel" "its ORCH:LAWS section could not be read back"
  bak=$(backup_path "$f")
  if [ "$DRY" != "1" ]; then
    cp -p "$f" "$bak" || refuse "$rel" "could not back up the file it was about to rewrite"
    { head -n $((SEC_L1 - 1)) "$f"; cat "$BLOCK"; tail -n +$((SEC_L2 + 1)) "$f"; } > "$TMPD/sec.new" \
      || refuse "$rel" "could not stage the replaced section"
    cat "$TMPD/sec.new" > "$f" || refuse "$rel" "could not rewrite the section"
    WROTE=1
  fi
  SECTION_REPLACED=1
  emit replace "$rel#ORCH:LAWS" " (backup ${bak#$ROOT_DIR/}, compared against $BLOCK)"
}

# Set by marker_gate when this file's span is not the block and the unlock is on.
A_SEC_REPLACE=0; C_SEC_REPLACE=0
SEC_REPLACE=0
marker_gate() { # <file> <relative name> — refuses in the check script's own words
  local rc
  SEC_REPLACE=0
  marker_rc "$1"; rc=$?
  case "$rc" in
    2) refuse "$2" "it has a second $SEC_START marker (duplicate marker); one pair per file — repair it, then re-run" ;;
    3) refuse "$2" "it has $SEC_START with no matching $SEC_END (unterminated section); close the section, then re-run" ;;
    4) refuse "$2" "it has $SEC_END with no matching $SEC_START before it (orphan end marker); open the section, then re-run" ;;
  esac
  [ "$MARK_STARTS" = "1" ] || return 0
  section_is_block "$1" && return 0
  # A legitimate block that has drifted lands here too — an older plugin
  # version's wording, a re-wrap, an indent. Both remedies are named and the
  # non-destructive one comes first: "remove the markers" is bad advice about a
  # real block. Until one of them is taken this project cannot be re-inited for
  # any other reason, which is the price of never printing `kept` over a file
  # whose marked text is not the laws. --adopt buys no exemption: the ORCH:LAWS
  # section is the plugin's own text, and the project's laws live in LAWS.md.
  if unlocked; then SEC_REPLACE=1; return 0; fi
  refuse "$2" "its ORCH:LAWS section (lines ${SEC_L1}–${SEC_L2}) is not the current cadence block, compared against $BLOCK — re-run under ORCH_CADENCE_UNLOCK=1 to replace that section with the current block (the old file is kept as $2.bak), or remove the markers and re-run"
}

# The block's own interior, read by the same span rule, computed once.
BLOCK_WANT="$TMPD/block.interior"
section_span "$BLOCK" || refuse "" "the cadence block at $BLOCK carries no ORCH:LAWS marker pair"
section_interior "$BLOCK" "$SEC_L1" "$SEC_L2" > "$BLOCK_WANT" \
  || refuse "" "the cadence block at $BLOCK could not be read"

marker_gate "$AGENTS_F" "AGENTS.md"; A_STARTS="$MARK_STARTS"; A_SEC_REPLACE="$SEC_REPLACE"
marker_gate "$CLAUDE_F" "CLAUDE.md"; C_SEC_REPLACE="$SEC_REPLACE"

# A block written into a file whose fences do not balance is a block inside a
# fence, where it reads as sample text and governs nothing. Refuse rather than
# bury it. Both fence syntaxes count, and each is counted on its own: a ```
# block may legitimately contain a ~~~ line and the reverse. Both paths that
# write the block into an existing file run this — the append at the end of the
# file, and the unlock's replacement at the marker pair — in the same words,
# each with its own verb. One tool, one file, one answer.
fence_parity() { # <file> <relative name> <appending|replacing>
  local f="$1" rel="$2" verb="$3" ticks tildes
  ticks=$(grep -c '^[[:space:]]*```' "$f" 2>/dev/null | tr -d ' ')
  tildes=$(grep -c '^[[:space:]]*~~~' "$f" 2>/dev/null | tr -d ' ')
  [ -n "$ticks" ] || ticks=0
  [ -n "$tildes" ] || tildes=0
  if [ $((ticks % 2)) -ne 0 ] || [ $((tildes % 2)) -ne 0 ]; then
    refuse "$rel" "its last code fence is never closed ($ticks \`\`\` lines, $tildes ~~~ lines) — $verb the block there would bury it inside the fence; close the fence, then re-run"
  fi
}

AGENTS_ACTION="create"
if [ -f "$AGENTS_F" ]; then
  if [ "$A_STARTS" = "1" ]; then
    AGENTS_ACTION="keep"
    # `keep` here covers the branch that REPLACES the span under the unlock, and
    # that write lands wherever the marker pair sits — under an unclosed opener
    # included. The preflight is where it must be caught: nothing written yet.
    if [ "$A_SEC_REPLACE" = "1" ]; then fence_parity "$AGENTS_F" "AGENTS.md" replacing; fi
  else
    fence_parity "$AGENTS_F" "AGENTS.md" appending
    AGENTS_ACTION="append"
  fi
fi

# CLAUDE.md: `@AGENTS.md` counts only as LINE 1, compared as a fixed string.
# Anywhere else it is prose or sample text, and the session never imports it.
# (A YAML frontmatter block is not a CLAUDE.md feature — Claude Code reads the
# file's first line as the first line — so line 1 stays the rule.)
CLAUDE_ACTION="create"
if [ -f "$CLAUDE_F" ]; then
  # The replacement is the one path on which this script writes the block into
  # CLAUDE.md, so it meets the same fence gate AGENTS.md's replacement does.
  if [ "$C_SEC_REPLACE" = "1" ]; then fence_parity "$CLAUDE_F" "CLAUDE.md" replacing; fi
  line1=$(head -1 "$CLAUDE_F" 2>/dev/null)
  line1="${line1%"${line1##*[![:space:]]}"}"   # trailing whitespace tolerated
  if [ "$line1" = "@AGENTS.md" ]; then CLAUDE_ACTION="keep"; else CLAUDE_ACTION="insert"; fi
fi

if [ -f "$SETTINGS_F" ] && ! have_py; then
  refuse "$SETTINGS_REL" "NEEDS python3 to merge the deny rules into an existing settings file structurally (set ORCH_CADENCE_PYTHON to another interpreter); text-editing one is how a settings file becomes a corrupt one"
fi

# The settings merge is a refusal that can fire, so it belongs in the preflight
# like every other one: run it in plan mode now, and only apply it later.
cat > "$TMPD/merge.py" <<'PYEOF'
import json, shutil, sys
path, mode, rules = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    with open(path) as fh:
        d = json.load(fh)
except Exception as exc:
    print("BAD does not parse as JSON: %s" % exc)
    sys.exit(2)
if not isinstance(d, dict):
    print("BAD its top level is not an object")
    sys.exit(2)
perms = d.get("permissions")
if perms is None:
    perms = {}
if not isinstance(perms, dict):
    print('BAD its "permissions" is not an object')
    sys.exit(2)
deny = perms.get("deny")
if deny is None:
    deny = []
if not isinstance(deny, list):
    print('BAD its "permissions.deny" is not a list')
    sys.exit(2)
missing = [r for r in rules if r not in deny]
if not missing:
    print("KEPT")
    sys.exit(0)
if mode != "apply":
    print("MERGED %d" % len(missing))
    sys.exit(0)
# The operator's file is copied aside BEFORE it is rewritten, and only when
# there is something to rewrite: a run that changes nothing leaves no .bak.
shutil.copy2(path, path + ".bak")
deny.extend(missing)
perms["deny"] = deny
d["permissions"] = perms
with open(path, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
print("MERGED %d" % len(missing))
PYEOF

merge_settings() { # <apply|plan> -> the verdict in $TMPD/merge.msg
  "$PY" "$TMPD/merge.py" "$SETTINGS_F" "$1" \
      'Edit(docs/llm-orchestrator/LAWS.md)' \
      'Edit(docs/llm-orchestrator/cadence.json)' \
      'Edit(docs/llm-orchestrator/LOCK.sha256)' \
      'Edit(.claude/settings.json)' \
      'Edit(.githooks/**)' > "$TMPD/merge.msg" 2>&1
  return $?
}
SETTINGS_PLAN=""
if [ -f "$SETTINGS_F" ]; then
  merge_settings plan
  SETTINGS_PLAN=$(head -1 "$TMPD/merge.msg")
  case "$SETTINGS_PLAN" in
    KEPT|MERGED\ *) ;;
    BAD\ *)         refuse "$SETTINGS_REL" "${SETTINGS_PLAN#BAD }" ;;
    *)              refuse "$SETTINGS_REL" "the merge could not be planned: $SETTINGS_PLAN" ;;
  esac
fi

# A write that cannot succeed is a refusal, and a refusal belongs here, not
# halfway through with `created` already printed for a file that is not there.
can_write "$ROOT_DIR" || refuse "" "$ROOT_DIR is not writable"
can_write "$ROOT_DIR/docs/llm-orchestrator" || refuse "docs/llm-orchestrator" "it cannot be written to — check its permissions"
can_write "$ROOT_DIR/.claude" || refuse ".claude" "it cannot be written to — check its permissions"
[ "$IS_GIT" = "1" ] && { can_write "$ROOT_DIR/.githooks" || refuse ".githooks" "it cannot be written to — check its permissions"; }
# `keep` excuses a file from the writability check only when nothing will be
# written to it. A marker pair sets the action to `keep` on the branch that
# REPLACES the span under the unlock, so the replace flag has to be consulted
# too — otherwise the one path that rewrites these files is the one path whose
# writability is never checked, and the failure surfaces halfway through, as a
# raw interpreter error behind a refusal with four documents already on disk.
{ [ "$AGENTS_ACTION" = "keep" ] && [ "$A_SEC_REPLACE" != "1" ]; } || can_write "$AGENTS_F" || refuse "AGENTS.md" "it cannot be written to — check its permissions"
{ [ "$CLAUDE_ACTION" = "keep" ] && [ "$C_SEC_REPLACE" != "1" ]; } || can_write "$CLAUDE_F" || refuse "CLAUDE.md" "it cannot be written to — check its permissions"
[ "$SETTINGS_PLAN" = "KEPT" ] || can_write "$SETTINGS_F" || refuse "$SETTINGS_REL" "it cannot be written to — check its permissions"
can_write "$GITIGNORE_F" || refuse "$GITIGNORE_REL" "it cannot be written to — check its permissions"

# The config that will land, resolved and validated before anything is written.
CFG_NEW="$TMPD/cadence.json"
if [ -n "$OPT_CONFIG" ]; then
  [ -f "$OPT_CONFIG" ] || refuse "" "--config names a file that does not exist: $OPT_CONFIG"
  CFG_SRC="$OPT_CONFIG"
else
  [ -f "$SCRIPT_DIR/cadence-detect.sh" ] \
    || refuse "" "cadence-detect.sh is not beside this script and no --config was given"
  bash "$SCRIPT_DIR/cadence-detect.sh" --root "$ROOT_DIR" > "$TMPD/detected.json" 2>"$TMPD/detect.err" \
    || refuse "" "the detector failed: $(head -1 "$TMPD/detect.err")"
  CFG_SRC="$TMPD/detected.json"
fi

if have_py; then
  "$PY" - "$CFG_SRC" "$CFG_NEW" > "$TMPD/cfg.msg" 2>&1 <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src) as fh:
        d = json.load(fh)
except Exception as exc:
    print("does not parse as JSON: %s" % exc)
    sys.exit(2)
if not isinstance(d, dict):
    print("its top level is not an object")
    sys.exit(2)
# Forced, not defaulted: a config whose "enabled" says false would install a
# cadence that is off while the report says a project was armed.
d["schema"] = 1
d["enabled"] = True
with open(dst, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
PYEOF
  [ $? -eq 0 ] || refuse "$CFG_REL" "$(head -1 "$TMPD/cfg.msg")"
else
  # No interpreter: the file is taken verbatim, so the two keys the whole design
  # reads have to be right already. The detector's proposals always are.
  grep -qE '"schema"[[:space:]]*:[[:space:]]*1([[:space:],}]|$)' "$CFG_SRC" \
    || refuse "$CFG_REL" "without python3 the config is copied verbatim and must already carry \"schema\": 1"
  grep -qE '"enabled"[[:space:]]*:[[:space:]]*true([[:space:],}]|$)' "$CFG_SRC" \
    || refuse "$CFG_REL" "without python3 the config is copied verbatim and must already carry \"enabled\": true"
  cp "$CFG_SRC" "$CFG_NEW" || refuse "$CFG_REL" "could not stage the config"
fi

# ---------- the report header -------------------------------------------------
if [ "$ADOPT" = "1" ]; then
  echo "cadence-init: $ROOT_DIR (adopt — files this project already has are kept as they are)"
else
  echo "cadence-init: $ROOT_DIR"
fi

# ---------- 1. the four law documents ----------------------------------------
LAWS_CREATED=0
[ "$DRY" = "1" ] || mkdir -p "$ROOT_DIR/docs/llm-orchestrator" || refuse "" "cannot create docs/llm-orchestrator under $ROOT_DIR"
# The report line comes AFTER the write, never before it: `created <path>` for a
# write that then failed is a report of work that did not happen.
copy_doc() { # <reference> <relative destination>
  local src="$REF_DIR/$1" dest="$ROOT_DIR/$2"
  if [ -f "$dest" ]; then emit keep "$2"; return 0; fi
  if [ "$DRY" != "1" ]; then
    cp "$src" "$dest" || refuse "$2" "could not write it"
    WROTE=1
  fi
  emit create "$2"
  [ "$2" = "$LAWS_REL" ] && LAWS_CREATED=1
  return 0
}
copy_doc laws.md           "$LAWS_REL"
copy_doc handoff.md        docs/llm-orchestrator/HANDOFF_TEMPLATE.md
copy_doc design-rulings.md docs/llm-orchestrator/DESIGN_RULINGS.md
copy_doc traps.md          docs/llm-orchestrator/TRAPS.md

# ---------- 2. AGENTS.md ------------------------------------------------------
case "$AGENTS_ACTION" in
  keep)
    # Under the unlock a span that is not the block is replaced whole; without
    # the unlock the preflight already refused, so `kept` here means the marked
    # text IS the block.
    if [ "$A_SEC_REPLACE" = "1" ]; then
      replace_section "$AGENTS_F" AGENTS.md
    else
      emit keep AGENTS.md
    fi
    ;;
  create)
    if [ "$DRY" != "1" ]; then
      { printf '# AGENTS.md\n\n'; cat "$BLOCK"; } > "$AGENTS_F" \
        || refuse AGENTS.md "could not write it"
      WROTE=1
    fi
    emit create AGENTS.md
    ;;
  append)
    if [ "$DRY" != "1" ]; then
      # One blank line before the block, and exactly one: a file that already
      # ends with a newline gets the separator, a file that does not gets its
      # terminator first.
      if [ -s "$AGENTS_F" ] && [ -n "$(tail -c 1 "$AGENTS_F")" ]; then printf '\n' >> "$AGENTS_F"; fi
      printf '\n' >> "$AGENTS_F" || refuse AGENTS.md "could not append the block"
      cat "$BLOCK" >> "$AGENTS_F" || refuse AGENTS.md "could not append the block"
      WROTE=1
    fi
    emit append AGENTS.md " (the ORCH:LAWS block)"
    ;;
esac

# ---------- 3. CLAUDE.md ------------------------------------------------------
# `@AGENTS.md` goes in as line 1. Line 1 of a file cannot be inside a code
# fence — a fence has to open on some earlier line — so insertion at the top is
# the one position that is always safe, and it is the position the import needs
# anyway. Every other byte is preserved: the rest of the file is appended
# untouched. Whether the import is already there was decided in the preflight,
# by a fixed-string comparison against LINE 1 — not by a search of the whole
# file, which counts a mention inside a code fence and a near-miss like
# `@AGENTSXmd` (the dot of a regex matches any character) as the real thing.
case "$CLAUDE_ACTION" in
  create)
    if [ "$DRY" != "1" ]; then
      { printf '@AGENTS.md\n\n'
        printf 'This project imports `AGENTS.md`, where its conventions and the cadence block live.\n'
      } > "$CLAUDE_F" || refuse CLAUDE.md "could not write it"
      WROTE=1
    fi
    emit create CLAUDE.md
    ;;
  keep)
    emit keep CLAUDE.md
    ;;
  insert)
    if [ "$DRY" != "1" ]; then
      { printf '@AGENTS.md\n'; cat "$CLAUDE_F"; } > "$TMPD/claude.new" \
        && cat "$TMPD/claude.new" > "$CLAUDE_F" || refuse CLAUDE.md "could not insert the import"
      WROTE=1
    fi
    emit insert CLAUDE.md " (@AGENTS.md as line 1)"
    ;;
esac
# The manifest hashes CLAUDE.md#ORCH:LAWS too, so the equality rule runs on both
# files — and the unlocked replacement is the ONE path on which this script ever
# writes the block into CLAUDE.md. It runs after the import, because an inserted
# line 1 moves every span below it.
if [ "$C_SEC_REPLACE" = "1" ]; then
  replace_section "$CLAUDE_F" CLAUDE.md
fi

# ---------- 4. .claude/settings.json -----------------------------------------
# The native deny rules are the primary lock in Claude Code: deny beats every
# hook and every allow, at every scope, with no trust dialog. Path rules are
# consulted for Edit and Read only, which is why every rule here is spelled
# Edit(...) — a Write(...) rule would be accepted, never consulted, and would
# warn at startup.
if [ ! -f "$SETTINGS_F" ]; then
  if [ "$DRY" != "1" ]; then
    mkdir -p "$ROOT_DIR/.claude" || refuse "$SETTINGS_REL" "cannot create .claude/"
    cat > "$SETTINGS_F" <<'JSON'
{
  "permissions": {
    "deny": [
      "Edit(docs/llm-orchestrator/LAWS.md)",
      "Edit(docs/llm-orchestrator/cadence.json)",
      "Edit(docs/llm-orchestrator/LOCK.sha256)",
      "Edit(.claude/settings.json)",
      "Edit(.githooks/**)"
    ]
  }
}
JSON
    MERGE_RC=$?
    { [ "$MERGE_RC" -eq 0 ] && [ -s "$SETTINGS_F" ]; } || refuse "$SETTINGS_REL" "could not write it"
    WROTE=1
  fi
  emit create "$SETTINGS_REL"
else
  # The plan came from the preflight; only the apply happens here.
  case "$SETTINGS_PLAN" in
    KEPT)
      emit keep "$SETTINGS_REL"
      ;;
    MERGED\ *)
      if [ "$DRY" != "1" ]; then
        merge_settings apply
        MERGE_RC=$?
        MERGE_MSG=$(head -1 "$TMPD/merge.msg")
        case "$MERGE_MSG" in
          MERGED\ *) ;;
          BAD\ *)    refuse "$SETTINGS_REL" "${MERGE_MSG#BAD }" ;;
          *)         refuse "$SETTINGS_REL" "the merge failed (rc=$MERGE_RC): $MERGE_MSG" ;;
        esac
        WROTE=1
      fi
      emit merge "$SETTINGS_REL" " (+${SETTINGS_PLAN#MERGED } deny rules; original at ${SETTINGS_REL}.bak)"
      ;;
  esac
fi

# ---------- 4b. .gitignore ----------------------------------------------------
# The backup the merge leaves behind is a copy of the operator's own settings.
# The arming commit is a `git add -A`, so without a rule it goes into the
# repository along with everything else this run wrote.
GI_ADD=""
for rule in "$IGNORE_1" "$IGNORE_2" "$IGNORE_3" "$IGNORE_4"; do
  if [ -f "$GITIGNORE_F" ] && grep -qxF -- "$rule" "$GITIGNORE_F"; then continue; fi
  GI_ADD="${GI_ADD}${rule}
"
done
if [ -z "$GI_ADD" ]; then
  emit keep "$GITIGNORE_REL"
elif [ -f "$GITIGNORE_F" ]; then
  if [ "$DRY" != "1" ]; then
    if [ -s "$GITIGNORE_F" ] && [ -n "$(tail -c 1 "$GITIGNORE_F")" ]; then printf '\n' >> "$GITIGNORE_F"; fi
    printf '%s' "$GI_ADD" >> "$GITIGNORE_F" || refuse "$GITIGNORE_REL" "could not append to it"
    WROTE=1
  fi
  emit append "$GITIGNORE_REL" " (the backups this script can leave)"
else
  if [ "$DRY" != "1" ]; then
    printf '%s' "$GI_ADD" > "$GITIGNORE_F" || refuse "$GITIGNORE_REL" "could not write it"
    WROTE=1
  fi
  emit create "$GITIGNORE_REL"
fi

# ---------- 5. .githooks ------------------------------------------------------
# The git layer is the only enforcement that crosses editors, agent harnesses
# and CI. The check script is COPIED in, not referenced, so the project needs no
# plugin on the machine that clones it.

# A hook the project wrote itself and that was KEPT means the git layer is not
# installed: the manifest hashes THAT hook, so `lock OK` is true and reads as
# the layer holding while an unruled laws edit would land.
GIT_LAYER_FOREIGN=""
install_hook() { # <source> <relative destination>
  local src="$1" rel="$2" dest="$ROOT_DIR/$2" bak
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    emit keep "$rel"
    [ "$DRY" = "1" ] || chmod +x "$dest" 2>/dev/null
    return 0
  fi
  if [ -f "$dest" ] && ! unlocked; then
    emit keep "$rel" " (it differs from the shipped one — this project's own hook is what git runs; ORCH_CADENCE_UNLOCK=1 replaces it)"
    GIT_LAYER_FOREIGN="$rel"
    return 0
  fi
  if [ ! -f "$dest" ]; then
    if [ "$DRY" != "1" ]; then cp "$src" "$dest" || refuse "$rel" "could not write it"; WROTE=1; fi
    emit create "$rel"
  else
    bak=$(backup_path "$dest")
    if [ "$DRY" != "1" ]; then
      cp -p "$dest" "$bak" || refuse "$rel" "could not back up the hook it was about to replace"
      cp "$src" "$dest" || refuse "$rel" "could not write it"
      WROTE=1
    fi
    emit replace "$rel" " (backup ${bak#$ROOT_DIR/})"
  fi
  [ "$DRY" = "1" ] || chmod +x "$dest" 2>/dev/null
  return 0
}
# Hooks under a directory git never reads are enforcement that does not exist,
# and the hooks-path one-liner is an instruction that cannot be followed there.
if [ "$IS_GIT" != "1" ]; then
  echo "git layer skipped: not a git repository"
else
  [ "$DRY" = "1" ] || mkdir -p "$ROOT_DIR/.githooks" || refuse "" "cannot create .githooks under $ROOT_DIR"
  install_hook "$REF_DIR/commit-msg" .githooks/commit-msg
  install_hook "$CHECK"              .githooks/orch-cadence-check.sh
  if [ -n "$GIT_LAYER_FOREIGN" ]; then
    echo "git layer NOT installed: $GIT_LAYER_FOREIGN differs from the shipped hook (re-run under the unlock to replace it)"
  fi
fi

# ---------- 6. cadence.json, LAST --------------------------------------------
CFG_F="$ROOT_DIR/$CFG_REL"
CFG_WRITE=0
if [ ! -f "$CFG_F" ]; then
  CFG_WRITE=1; CFG_VERB=create; CFG_SUFFIX=""
elif cmp -s "$CFG_NEW" "$CFG_F"; then
  CFG_VERB=keep; CFG_SUFFIX=""
elif unlocked; then
  CFG_WRITE=1; CFG_VERB=replace; CFG_SUFFIX=""
else
  CFG_VERB=keep; CFG_SUFFIX=" (it differs from the one proposed; ORCH_CADENCE_UNLOCK=1 replaces it)"
fi
if [ "$CFG_WRITE" = "1" ] && [ "$DRY" != "1" ]; then
  cp "$CFG_NEW" "$CFG_F" || refuse "$CFG_REL" "could not write it"
  WROTE=1
fi
emit "$CFG_VERB" "$CFG_REL" "$CFG_SUFFIX"

# ---------- 7. the lock, the verdict, the recipe ------------------------------
CURRENT_HOOKSPATH=""
[ "$IS_GIT" = "1" ] && CURRENT_HOOKSPATH=$(git -C "$ROOT_DIR" config core.hooksPath 2>/dev/null)

if [ "$DRY" = "1" ]; then
  echo "would run: orch-cadence-check.sh --root \"$ROOT_DIR\" --lock"
  echo "(--dry-run: nothing above was written)"
  print_tip
  exit 0
fi

# --lock refuses over a manifest that already exists unless the person launched
# the session with the unlock. On a re-run that is the EXPECTED answer, so it is
# reported as the no-op it is: a REFUSED line in a run that exits 0 teaches the
# reader to read refusals as noise. It is only a failure when the project ends
# this run with no manifest at all.
if [ -f "$ROOT_DIR/$LOCK_REL" ] && ! unlocked; then
  echo "lock kept (already armed; re-run under ORCH_CADENCE_UNLOCK=1 to re-lock)"
else
  bash "$CHECK" --root "$ROOT_DIR" --lock 2>&1 | sed 's/^/  /'
  if [ ! -f "$ROOT_DIR/$LOCK_REL" ]; then
    echo "refused $LOCK_REL: the lock did not arm — the line above says why"
    exit 1
  fi
fi

VERDICT=$(bash "$CHECK" --root "$ROOT_DIR" --verdict 2>/dev/null)
[ -n "$GIT_LAYER_FOREIGN" ] && VERDICT="$VERDICT · git layer: not installed"
printf '%s\n' "$VERDICT"
print_tip

# The recipe that takes the project from written to armed, in the order it has
# to be run. Two steps printed in the wrong order walk the reader into a hook
# refusal: a commit made before the re-lock is a commit the manifest disagrees
# with, and placeholders filled after the lock leave a manifest describing a
# file nobody has.
# A run that REPLACED a marked section did not arm a fresh project: it rewrote
# a laws section in a project that already had one. That commit is not the
# arming commit, so the hook demands a numbered ruling in its message, and the
# manifest has to be rewritten under the unlock before it.
if [ "$SECTION_REPLACED" = "1" ]; then
  echo "next: this run replaced an ORCH:LAWS section. In order:"
else
  echo "next: this project is written, not yet armed. In order:"
fi
STEP=0
if [ "$LAWS_CREATED" = "1" ]; then
  STEP=$((STEP+1)); echo "  $STEP. fill in every <PLACEHOLDER> in $LAWS_REL — it is a template until you do"
  STEP=$((STEP+1)); echo "  $STEP. re-lock, because step $((STEP-1)) changes the laws after this run's manifest: ORCH_CADENCE_UNLOCK=1 bash \"$CHECK\" --root \"$ROOT_DIR\" --lock"
elif [ "$SECTION_REPLACED" = "1" ]; then
  STEP=$((STEP+1)); echo "  $STEP. re-lock, because this run rewrote a section the manifest covers: ORCH_CADENCE_UNLOCK=1 bash \"$CHECK\" --root \"$ROOT_DIR\" --lock"
fi
if [ "$IS_GIT" = "1" ]; then
  STEP=$((STEP+1))
  if [ "$CURRENT_HOOKSPATH" = ".githooks" ]; then
    echo "  $STEP. route this clone's hooks: already done here (git config core.hooksPath .githooks)"
  else
    echo "  $STEP. route this clone's hooks, once per clone: git config core.hooksPath .githooks"
  fi
  STEP=$((STEP+1))
  if [ "$SECTION_REPLACED" = "1" ]; then
    echo "  $STEP. commit what was written — this project was already armed, so the message needs a NUMBERED RULING or the commit-msg hook refuses it: git add -A && git commit -m \"ruling N: replace the ORCH:LAWS section with the current cadence block\""
  else
    echo "  $STEP. commit what was written — this first commit needs no numbered ruling: git add -A && git commit -m \"arm the cadence\""
  fi
  # The last layer of the alarm, and the only one that still speaks in a clone
  # whose hooks were never routed or whose commit stepped past them.
  STEP=$((STEP+1))
  echo "  $STEP. in CI, run .githooks/orch-cadence-check.sh --audit HEAD (see docs/install.md, \"The lock's two layers\")"
fi
exit 0
