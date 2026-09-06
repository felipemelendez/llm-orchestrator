#!/usr/bin/env bash
# orch-cadence-gate.sh — the deterministic half of the fix-delta gate.
#
# WHAT
#   orch-cadence-gate.sh <path-to-tree> <base-sha> [--no-typecheck]
#                        [--families "<space-separated test paths>"]
#                        [--config <cadence.json>]
#
#   Steps, in order, every count read from a log and nothing piped to tail:
#     0 inventory     changed tracked production files, changed tests, untracked
#                     new files, comment-only detection, shasums at the start
#     1 export sweep  every production file whose export set changed, ADDED and
#                     REMOVED, with the suites that name it (a re-export is not a
#                     removal; a removed name still referenced is reported)
#     2 families      the changed suites plus the suites that import a changed
#                     production file, run once
#     3 revert-to-red each changed production file reverted ALONE to base, its
#                     importers and the changed suites that name it run, the file
#                     restored and cmp'd. Verdicts:
#                       REVERT_RED                 a named pin turned red
#                       REVERT_RED_BY_LOAD_FAILURE the run died with 0 failures —
#                                                  breakage, not pin proof
#                       REVERT_STAYS_GREEN         no pin turns red
#                       COMMENT_ONLY / NEW_FILE / NATIVE  not provable at file level
#     4 typecheck     the config's typecheck_cmd (or `bash -n` for shell-suites)
#                     plus a positive control appended to a real changed file,
#                     which MUST produce the config's marker, restored cmp-identical
#     5 shasum proof  every changed and untracked file byte-identical to the start
#
# WHY IT COPIES
#   The gate mutates files to learn whether a pin covers them. It must therefore
#   never be pointed at a tree anyone cares about: it copies the WHOLE target
#   (cp -cR when the filesystem can clone, else cp -R) into a scratch directory
#   and works only there. It registers no git worktree — that would write to the
#   target's .git — and when the target is a linked worktree, whose index lives
#   in the main repository, it works against a COPY of that index so no git
#   command can touch the original. A trap on EXIT/INT/TERM restores whatever is
#   currently reverted, prints the shasum proof, and removes the copy.
#
# EXIT CODES
#   0  the run completed
#   3  RUNNER_UNKNOWN — no shipped profile and no test_cmd; steps 2 and 3 skipped
#   4  a restore failed, or the shasum proof did not match
#   5  a bounded wait loop expired (reported loudly, the run continued)
#   9  refused (bad arguments, a target that is not a git working tree, a base
#      that is not an ancestor of HEAD, a target matching refuse_paths)
#   130 interrupted
#   Nothing else moves it. The exit code reports the gate's own integrity:
#   a red family run and a REVERT_STAYS_GREEN verdict both leave it 0, and
#   the seat is what reads the verdicts.
#
# WHAT IT DOES NOT DO
#   It never consults `enabled` in cadence.json. This is an explicit tool: you
#   point it at a tree and it grades that tree. The on/off switch belongs to the
#   things that run by themselves — the verdict line and the commit-msg hook.
#   It never follows a symlink. A changed or untracked path that is a link gets
#   a SYMLINK verdict of its own and is excluded from the revert, from the
#   positive control and from the content shasums (the link's TARGET STRING is
#   hashed instead): an absolute link inside a copy still points into the tree
#   the gate was told not to touch.
#   The shipped profile table lives in cadence-detect.sh, not here — one table,
#   no drift — so the gate hard-depends on that sibling and refuses without it.
#   Two keys the gate reads beyond §4's schema: `lang_globs` (which extensions
#   the runner's language covers; a changed file outside them is NATIVE) and
#   `suite_globs` (the RUNNABLE subset of the test files; without it every test
#   file is treated as runnable). Both are emitted by every shipped profile,
#   empty where the profile does not use them.
#   COMMENT_ONLY is decided by the profile's comment_prefixes on the changed
#   lines alone, with no block comment state: for jest/vitest a changed line
#   starting with `*` inside a `/* … */` block comment counts as CODE, not as a
#   comment, so such a file is reverted and graded rather than skipped. Tracking
#   the block state costs more than the verdict is worth; the loss is one
#   needless revert, never a missed one.
#
# NOTES
#   python3 is REQUIRED here (the whole config, arrays included, must be read):
#   the gate refuses loudly rather than grading with half a config.
#   Bash 3.2 compatible: no associative arrays, no mapfile, dedup via sorted files.  # portable-ok

set -uo pipefail
# The gate's OWN greps and seds run under LC_ALL=C so bytes stay bytes. The
# suites it spawns must see the CALLER's locale instead: a C locale exported
# into a suite turned one Unicode-arrow assertion silent and printed a false
# family red. Every spawn goes through spawn_env(), which restores the caller's
# LC_ALL (or unsets it) and drops the gate's index isolation — the same class
# of leak the GIT_INDEX_FILE export had, so both are handled in one place.
_ORCH_CALLER_LC_ALL="${LC_ALL-}"; _ORCH_CALLER_LC_ALL_SET="${LC_ALL+1}"
LC_ALL=C
export LC_ALL
spawn_env() {
  if [ -n "${_ORCH_CALLER_LC_ALL_SET}" ]; then LC_ALL="${_ORCH_CALLER_LC_ALL}"; export LC_ALL; else unset LC_ALL; fi
  unset GIT_INDEX_FILE
}
# A caller's GIT_INDEX_FILE (a git hook, a nested gate) is never the target's
# index: inheriting it doubled the inventory and printed a false INDEX_ISOLATED
# line. The gate reads the copy's own index; the only export of this variable
# is the isolation below, for a linked-worktree target.
unset GIT_INDEX_FILE

# fd 9 is the script's own stdout, saved before anything can redirect it. The
# EXIT/INT trap writes its restore proof and its EXIT= line THERE: an
# interrupt can land inside a function call that carries a redirect (step 1
# and step 3 both make them), and a trap firing at that moment inherits the
# redirect - measured: the whole proof went into a scratch file and the
# caller's log simply stopped, with no EXIT line at all.
exec 9>&1
RC=0
CLEANED=0
STARTED=0
WORK=""
RUNDIR=""
EARLY=""
ALLFILES=""
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SELF_DIR/cadence-detect.sh"
PY="${ORCH_CADENCE_PYTHON:-python3}"

T0=$(date +%s)
elapsed() { echo "$(( $(date +%s) - T0 ))s"; }

sha_of() { # <file> -> sha256
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else echo "NO_SHA256_TOOL"; fi
}

sha_stdin() { # sha256 of stdin
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else echo "NO_SHA256_TOOL"; fi
}

sha_list() { # <listfile> <outfile>  (cwd must be the copy)
  : > "$2"
  [ -f "$1" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A symlink is proven by the string it holds. Reading THROUGH it would hash
    # a file that may live outside the copy entirely.
    if [ -L "$f" ]; then printf '%s  %s\n' "$(readlink "$f" | sha_stdin)" "$f" >> "$2"
    elif [ -f "$f" ]; then printf '%s  %s\n' "$(sha_of "$f")" "$f" >> "$2"
    fi
  done < "$1"
  return 0
}

restore_active() {
  local keep rel
  if [ -n "$RUNDIR" ] && [ -f "$RUNDIR/active_revert" ]; then
    keep=$(sed -n '1p' "$RUNDIR/active_revert")
    rel=$(sed -n '2p' "$RUNDIR/active_revert")
    if [ -n "$keep" ] && [ -f "$keep" ] && [ -n "$rel" ] && [ -n "$WORK" ]; then
      cp "$keep" "$WORK/$rel"
      if cmp -s "$keep" "$WORK/$rel"; then echo "RESTORED $rel cmp-identical"
      else echo "RESTORE_FAILED $rel"; RC=4; fi
    fi
    rm -f "$RUNDIR/active_revert"
  fi
  if [ -n "$RUNDIR" ] && [ -f "$RUNDIR/active_deleted" ]; then
    rel=$(sed -n '1p' "$RUNDIR/active_deleted")
    if [ -n "$rel" ] && [ -n "$WORK" ]; then
      rm -f "$WORK/$rel"
      if [ -e "$WORK/$rel" ]; then echo "RESTORE_FAILED $rel"; RC=4
      else echo "RESTORED $rel deleted again, as the tree had it"; fi
    fi
    rm -f "$RUNDIR/active_deleted"
  fi
  if [ -n "$RUNDIR" ] && [ -f "$RUNDIR/active_control" ]; then
    keep=$(sed -n '1p' "$RUNDIR/active_control")
    rel=$(sed -n '2p' "$RUNDIR/active_control")
    if [ -n "$keep" ] && [ -f "$keep" ] && [ -n "$rel" ] && [ -n "$WORK" ]; then
      cp "$keep" "$WORK/$rel"
      if cmp -s "$keep" "$WORK/$rel"; then echo "CONTROL_RESTORED cmp-identical"
      else echo "CONTROL_RESTORE_FAILED $rel"; RC=4; fi
    fi
    rm -f "$RUNDIR/active_control"
  fi
}

cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  { cleanup_body; } >&9
  # The proof can only be trusted if it also decides the exit code: the shasum
  # comparison and the restores run INSIDE this trap, so a failure discovered
  # here has to reach the caller, not just the printed EXIT= line.
  exit "$RC"
}

cleanup_body() {
  if [ "$STARTED" = "1" ]; then
    restore_active
    echo "== 5 shasum proof =="
    if [ -n "$WORK" ] && [ -d "$WORK" ] && [ -n "$ALLFILES" ] && [ -f "$ALLFILES" ]; then
      ( cd "$WORK" && sha_list "$ALLFILES" "$RUNDIR/sha_end.txt" )
      if diff -q "$RUNDIR/sha_start.txt" "$RUNDIR/sha_end.txt" >/dev/null 2>&1; then
        echo "SHASUMS_RESTORED ok ($(grep -c . "$RUNDIR/sha_start.txt" | tr -d ' ') files)"
      else
        echo "SHASUMS_CHANGED:"; diff "$RUNDIR/sha_start.txt" "$RUNDIR/sha_end.txt"; RC=4
      fi
    else
      echo "SHASUM_PROOF_SKIPPED (the copy was never made)"
    fi
    echo "GATE Finished: $(date '+%Y-%m-%d %H:%M:%S') elapsed=$(elapsed)"
  fi
  # The copy is the only thing the gate ever created outside its scratch dir.
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    case "$WORK" in "$RUNDIR"/*) rm -rf "$WORK" ;; esac
  fi
  [ -n "$EARLY" ] && [ -d "$EARLY" ] && rm -rf "$EARLY"
  echo "EXIT=$RC"
}
trap cleanup EXIT
trap 'RC=130; exit 130' INT TERM

refuse() { echo "REFUSED: $1"; RC=9; exit 9; }

# ---------- arguments ---------------------------------------------------------
TARGET="${1:-}"; BASE="${2:-}"
if [ -z "$TARGET" ] || [ -z "$BASE" ]; then
  echo "usage: orch-cadence-gate.sh <path-to-tree> <base-sha> [--no-typecheck] [--families \"...\"] [--config <cadence.json>]"
  RC=9; exit 9
fi
shift 2
NO_TYPECHECK=0; FAMS=""; CONFIG_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-typecheck) NO_TYPECHECK=1 ;;
    --families)     shift; FAMS="${1:-}" ;;
    --config)       shift; CONFIG_OPT="${1:-}" ;;
    *)              echo "unknown option: $1"; RC=9; exit 9 ;;
  esac
  shift
done
TARGET="${TARGET%/}"

command -v "$PY" >/dev/null 2>&1 || { echo "NEEDS python3: the gate reads the whole cadence.json, arrays included"; RC=9; exit 9; }
# The profile table is deliberately in one place, and that place is next door.
# Without it the gate would silently grade with an empty set of defaults.
[ -f "$DETECT" ] || { echo "NEEDS cadence-detect.sh beside me (looked in $SELF_DIR)"; RC=9; exit 9; }

# ---------- refusals ----------------------------------------------------------
[ -e "$TARGET" ] || refuse "$TARGET does not exist"
[ -d "$TARGET" ] || refuse "$TARGET is not a directory"
# pwd -P on both sides: on macOS /var is a symlink to /private/var, so the
# logical path and git's resolved toplevel are the same directory spelled twice.
TARGET="$(cd "$TARGET" && pwd -P)"
TOP="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$TOP" ] || refuse "$TARGET is not inside a git working tree"
TOP="$(cd "$TOP" 2>/dev/null && pwd -P)"
[ "$TOP" = "$TARGET" ] || refuse "$TARGET is not the toplevel of its working tree ($TOP is)"
git -C "$TARGET" rev-parse --verify -q "${BASE}^{commit}" >/dev/null 2>&1 || refuse "base $BASE is not a commit in $TARGET"
git -C "$TARGET" merge-base --is-ancestor "$BASE" HEAD 2>/dev/null \
  || refuse "base $BASE is not an ancestor of HEAD in $TARGET (the gate grades a working-tree delta over an ancestor)"

# ---------- config ------------------------------------------------------------
# GNU mktemp -d refuses when TMPDIR names a directory that does not exist
# ("failed to create directory via template"); BSD mktemp -d ignores it and
# falls back to /var/folders. Create it so the gate behaves the same on both.
if [ -n "${TMPDIR:-}" ] && [ ! -d "$TMPDIR" ]; then
  mkdir -p "$TMPDIR" || refuse "cannot create TMPDIR $TMPDIR"
fi
EARLY="$(mktemp -d)"
[ -n "$EARLY" ] && [ -d "$EARLY" ] || refuse "cannot create a temporary directory (TMPDIR=${TMPDIR:-<unset>})"
CFG_SRC=""
CONFIG_NOTE=""
if [ -n "$CONFIG_OPT" ]; then
  [ -f "$CONFIG_OPT" ] || refuse "no config at $CONFIG_OPT"
  CFG_SRC="$CONFIG_OPT"
elif [ -f "$TARGET/docs/llm-orchestrator/cadence.json" ]; then
  CFG_SRC="$TARGET/docs/llm-orchestrator/cadence.json"
else
  bash "$DETECT" --root "$TARGET" > "$EARLY/detected.json" 2>/dev/null
  CFG_SRC="$EARLY/detected.json"
  CONFIG_NOTE="CONFIG_ABSENT: using detected profile $(sed -n 's/.*"profile": "\([^"]*\)".*/\1/p' "$CFG_SRC" | head -1)"
fi

PROFILE_NAME=$("$PY" -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(""); raise SystemExit(0)
print((d.get("runner") or {}).get("profile") or "")' "$CFG_SRC" 2>/dev/null)
bash "$DETECT" --profile "${PROFILE_NAME:-unknown}" > "$EARLY/defaults.json" 2>/dev/null

# The shipped profile supplies the defaults; the project's file overrides them,
# key by key, so a config may name a profile and change one regex.
"$PY" - "$EARLY/defaults.json" "$CFG_SRC" "$EARLY/config.json" <<'PYEOF'
import json, sys
def merge(a, b):
    out = dict(a)
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = v
    return out
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
try:
    c = json.load(open(sys.argv[2]))
except Exception as e:
    sys.stderr.write("CONFIG_UNPARSEABLE: %s\n" % e)
    sys.exit(1)
json.dump(merge(d, c), open(sys.argv[3], "w"), indent=1)
PYEOF
[ $? -eq 0 ] || refuse "$CFG_SRC does not parse as JSON"

DUMP="$EARLY/cfg.dump"
"$PY" - "$EARLY/config.json" > "$DUMP" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
def emit(k, v):
    if isinstance(v, list):
        for x in v: print("A\t%s\t%s" % (k, x))
    elif isinstance(v, dict):
        for kk, vv in v.items(): emit(k + "." + kk, vv)
    elif isinstance(v, bool): print("S\t%s\t%s" % (k, "true" if v else "false"))
    elif v is None: print("S\t%s\t" % k)
    else: print("S\t%s\t%s" % (k, v))
for k, v in d.items(): emit(k, v)
PYEOF

cfg_s() { awk -F'\t' -v k="$1" '$1=="S" && $2==k {print $3; exit}' "$DUMP"; }
cfg_a() { awk -F'\t' -v k="$1" '$1=="A" && $2==k {print $3}' "$DUMP"; }

PROFILE=$(cfg_s runner.profile)
TEST_CMD=$(cfg_s runner.test_cmd)
SUMMARY_RE=$(cfg_s runner.summary_re)
FAIL_RE=$(cfg_s runner.fail_count_re)
SUITES_RE=$(cfg_s runner.suites_re)
TYPECHECK_CMD=$(cfg_s typecheck_cmd)
UNUSED_CMD=$(cfg_s unused_cmd)
EXPORT_PATTERN=$(cfg_s export_pattern)
WAIT_TIMEOUT=$(cfg_s wait_timeout_s); [ -n "$WAIT_TIMEOUT" ] || WAIT_TIMEOUT=1800
# "30s" or 1800.5 make every [ -ge ] in the wait loop error out, which reads as
# false, which is an unbounded wait. A bound that is not a whole number of
# seconds is not a bound.
case "$WAIT_TIMEOUT" in
  *[!0-9]*) echo "note: wait_timeout_s \"$WAIT_TIMEOUT\" is not a whole number of seconds — using 1800" >&2
            WAIT_TIMEOUT=1800 ;;
esac
RED_RE=$(cfg_s runner.red_re)
# What a red looks like when the runner prints no parseable count. Green is
# still decided by the exit code alone; this only separates a REAL red from a
# load failure, and every shape below is one this repo's own suites print.
# The count must be NON-ZERO: a runner that always prints "0 failed" would
# otherwise make every load failure look like a red.
[ -n "$RED_RE" ] || RED_RE='[1-9][0-9]* failed|FAILED|✗|^FAIL'  # portable-ok
INSTALL_CMD=$(cfg_s install_cmd)
SCRATCH_DIR=$(cfg_s scratch_dir)
PC_EXT=$(cfg_s positive_control.file_ext)
PC_SNIPPET=$(cfg_s positive_control.snippet)
PC_MARKER=$(cfg_s positive_control.expect_marker)

SRC_ROOTS=();       while IFS= read -r x; do [ -n "$x" ] && SRC_ROOTS+=("$x");       done < <(cfg_a src_roots)
PROD_GLOBS=();      while IFS= read -r x; do [ -n "$x" ] && PROD_GLOBS+=("$x");      done < <(cfg_a prod_globs)
TEST_GLOBS=();      while IFS= read -r x; do [ -n "$x" ] && TEST_GLOBS+=("$x");      done < <(cfg_a test_globs)
SUITE_GLOBS=();     while IFS= read -r x; do [ -n "$x" ] && SUITE_GLOBS+=("$x");     done < <(cfg_a suite_globs)
LANG_GLOBS=();      while IFS= read -r x; do [ -n "$x" ] && LANG_GLOBS+=("$x");      done < <(cfg_a lang_globs)
IMPORT_PATTERNS=(); while IFS= read -r x; do [ -n "$x" ] && IMPORT_PATTERNS+=("$x"); done < <(cfg_a import_patterns)
COMMENT_PREFIXES=();while IFS= read -r x; do [ -n "$x" ] && COMMENT_PREFIXES+=("$x");done < <(cfg_a comment_prefixes)
WAIT_PATTERNS=();   while IFS= read -r x; do [ -n "$x" ] && WAIT_PATTERNS+=("$x");   done < <(cfg_a wait_patterns)
REFUSE_PATHS=();    while IFS= read -r x; do [ -n "$x" ] && REFUSE_PATHS+=("$x");    done < <(cfg_a refuse_paths)

for pat in "${REFUSE_PATHS[@]+"${REFUSE_PATHS[@]}"}"; do
  case "$TARGET" in $pat) refuse "$TARGET matches refuse_paths entry '$pat'" ;; esac
done

RUNNER_UNKNOWN=0
case "$PROFILE" in
  jest|vitest|pytest|shell-suites) ;;
  *) [ -n "$TEST_CMD" ] || RUNNER_UNKNOWN=1 ;;
esac

# ---------- the throwaway copy ------------------------------------------------
SPROOT="$SCRATCH_DIR"
[ -n "$SPROOT" ] || SPROOT="${TMPDIR:-/tmp}/orch-cadence-gate"
SPROOT="${SPROOT%/}"
case "$SPROOT" in "$TARGET"|"$TARGET"/*) refuse "scratch_dir $SPROOT is inside the target" ;; esac
# A second-resolution tag is not a unique name: two gates started in the same
# second share a run directory, and the first to finish rm -rf's the other's
# copy mid-run. mktemp -d cannot collide.
mkdir -p "$SPROOT" || refuse "cannot create $SPROOT"
RUNDIR="$(mktemp -d "$SPROOT/$(basename "$TARGET").XXXXXX" 2>/dev/null)"
[ -n "$RUNDIR" ] && [ -d "$RUNDIR" ] || refuse "cannot create a run directory under $SPROOT"
WORK="$RUNDIR/copy"

STARTED=1
echo "GATE Started: $(date '+%Y-%m-%d %H:%M:%S') target=$TARGET base=$BASE profile=${PROFILE:-<none>} logs=$RUNDIR"
[ -n "$CONFIG_NOTE" ] && echo "$CONFIG_NOTE"

if cp -cR "$TARGET" "$WORK" 2>/dev/null; then
  echo "COPY cp -cR (clonefile) -> $WORK"
else
  rm -rf "$WORK"
  cp -R "$TARGET" "$WORK" 2>/dev/null || { echo "COPY_FAILED"; RC=9; exit 9; }
  echo "COPY cp -R -> $WORK"
fi

# Index isolation. A copy of a LINKED worktree still resolves its index inside
# the main repository, so every git command in the copy would write the target's
# index. Point GIT_INDEX_FILE at a copy of it instead.
IDXPATH="$(git -C "$WORK" rev-parse --git-path index 2>/dev/null)"
case "$IDXPATH" in /*) ;; *) IDXPATH="$WORK/$IDXPATH" ;; esac
case "$IDXPATH" in
  "$WORK"/*) echo "INDEX in the copy ($IDXPATH)" ;;
  *) cp "$IDXPATH" "$RUNDIR/index.iso" 2>/dev/null
     # An empty stand-in index is worse than no gate: git then reports nothing
     # changed and the run ends green on a tree it never read.
     [ -s "$RUNDIR/index.iso" ] || refuse "git could not read the copy: the target's index ($IDXPATH) is missing or empty"
     # The export is for the gate's OWN git calls and nothing else. Every
     # command the gate spawns — the suites, test_cmd, typecheck_cmd,
     # unused_cmd, install_cmd — runs inside ( spawn_env; … ), or a
     # suite's own `git init` fixtures would stage into this index and read
     # back the target's entries as their own.
     export GIT_INDEX_FILE="$RUNDIR/index.iso"
     echo "INDEX_ISOLATED the target's index is outside the copy; using $RUNDIR/index.iso" ;;
esac

cd "$WORK" || { echo "cannot enter $WORK"; RC=9; exit 9; }

if [ -n "$INSTALL_CMD" ]; then
  ( spawn_env; eval "$INSTALL_CMD" ) > "$RUNDIR/install.log" 2>&1
  echo "INSTALL EXIT=$? [$(elapsed)] log=$RUNDIR/install.log"
fi

# ---------- helpers that need the config --------------------------------------
glob_match() { # <path> <glob>
  local f="$1" p="$2" prefix suffix rest
  # `**/` spans directories, including none of them: tests/**/test-*.sh has to
  # match tests/test-x.sh AND tests/handoff/test-x.sh. Collapsing it to
  # tests/test-*.sh (which is what a plain sed does) turns every pin in a
  # subdirectory into "no pin covers this file".
  case "$p" in
    *'**/'*)
      prefix="${p%%\*\*/*}"
      suffix="${p#*\*\*/}"
      case "$f" in "$prefix"*) ;; *) return 1 ;; esac
      rest="${f#"$prefix"}"
      while : ; do
        case "$rest" in $suffix) return 0 ;; esac
        case "$rest" in */*) rest="${rest#*/}" ;; *) break ;; esac
      done
      return 1 ;;
  esac
  p=$(printf '%s' "$p" | sed 's|\*\*|*|g')
  case "$p" in
    */) case "$f" in *"$p"*) return 0 ;; esac ;;
    *)  case "$f" in $p|*/$p) return 0 ;; esac ;;
  esac
  return 1
}
any_glob() { # <path> <glob...>
  local f="$1"; shift
  local g
  for g in "$@"; do glob_match "$f" "$g" && return 0; done
  return 1
}
is_test() { any_glob "$1" "${TEST_GLOBS[@]+"${TEST_GLOBS[@]}"}"; }
# A test FILE is not always a runnable SUITE: a shell project's tests/ holds a
# runner and a helper library beside its suites, and running the runner as a
# suite would run the whole tree inside the gate. suite_globs, when the profile
# sets it, is the runnable subset; otherwise every test file is runnable.
is_suite() { [ ${#SUITE_GLOBS[@]} -eq 0 ] && { is_test "$1"; return $?; }; any_glob "$1" "${SUITE_GLOBS[@]+"${SUITE_GLOBS[@]}"}"; }
is_prod() { is_test "$1" && return 1; any_glob "$1" "${PROD_GLOBS[@]+"${PROD_GLOBS[@]}"}"; }
in_lang() { [ ${#LANG_GLOBS[@]} -eq 0 ] && return 0; any_glob "$1" "${LANG_GLOBS[@]+"${LANG_GLOBS[@]}"}"; }

COMMENT_RE=""
build_comment_re() {
  local p esc alt=""
  for p in "${COMMENT_PREFIXES[@]+"${COMMENT_PREFIXES[@]}"}"; do
    esc=$(printf '%s' "$p" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
    alt="${alt}|${esc}"
  done
  COMMENT_RE="^[+-][[:space:]]*(\$${alt})"
}
build_comment_re

comment_only() { # 0 = every changed line is blank or a comment
  git diff "$BASE" -- "$1" \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE "$COMMENT_RE" | grep -q .
  [ $? -eq 0 ] && return 1
  return 0
}

importers_of() { # <path> -> the test files that name it
  local f="$1" b p pat
  b=$(basename "$f"); b="${b%.*}"
  : > "$RUNDIR/imp.tmp"
  for pat in "${IMPORT_PATTERNS[@]+"${IMPORT_PATTERNS[@]}"}"; do
    p=$(printf '%s' "$pat" | sed "s|{base}|$b|g")
    grep -rlE -- "$p" "${SRC_ROOTS[@]+"${SRC_ROOTS[@]}"}" 2>/dev/null >> "$RUNDIR/imp.tmp"
  done
  sort -u "$RUNDIR/imp.tmp" | while IFS= read -r t; do
    [ -n "$t" ] || continue
    t="${t#./}"
    is_suite "$t" && printf '%s\n' "$t"
  done
}

WAIT_EXPIRED="$RUNDIR/wait_expired"; : > "$WAIT_EXPIRED"
wait_for_quiet() {
  local pat iv waited
  for pat in "${WAIT_PATTERNS[@]+"${WAIT_PATTERNS[@]}"}"; do
    [ -n "$pat" ] || continue
    grep -qxF -- "$pat" "$WAIT_EXPIRED" 2>/dev/null && continue
    iv=5; [ "$WAIT_TIMEOUT" -lt 10 ] && iv=1
    waited=0
    while pgrep -f "$pat" >/dev/null 2>&1; do
      if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
        echo "WAIT_TIMEOUT $pat after ${waited}s — continuing anyway"
        printf '%s\n' "$pat" >> "$WAIT_EXPIRED"
        [ "$RC" -eq 0 ] && RC=5
        break
      fi
      sleep "$iv"; waited=$((waited + iv))
    done
  done
}

run_suites() { # <logfile> <suite...>  -> the runner's exit code
  local log="$1"; shift
  : > "$log"
  local rc=0 s
  if [ "$PROFILE" = "shell-suites" ] && [ -z "$TEST_CMD" ]; then
    for s in "$@"; do
      echo "--- $s" >> "$log"
      ( spawn_env; bash "$s" ) >> "$log" 2>&1 || rc=1
    done
    return $rc
  fi
  ( spawn_env; eval "$TEST_CMD \"\$@\"" ) >> "$log" 2>&1
  return $?
}

# A suite's summary is the LAST matching line inside its own block: run_suites
# writes "--- <suite>" ahead of each one, so a fixture line a passing suite
# prints on its way ("0 passed, 1 failed." from a nested run) is not that
# suite's verdict and must not be counted. A runner invoked once for all suites
# writes no markers; the whole log is then one block, as before.
per_suite_summaries() { # <logfile> -> one line per suite
  awk -v re="$SUMMARY_RE" '
    /^--- / { if (n) print cur; cur=""; n=0; next }
    $0 ~ re { cur=$0; n=1 }
    END { if (n) print cur }' "$1" 2>/dev/null
}
line_fail_count() { # <summary-line>
  printf '%s\n' "$1" | grep -oE "$FAIL_RE" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}'
}
fail_count_from() { # <logfile>
  local n=0 line c
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    c=$(line_fail_count "$line"); n=$((n + ${c:-0}))
  done <<EOF
$(per_suite_summaries "$1")
EOF
  echo "$n"
}
# The line worth showing is the one that went red, not whichever suite ran last.
summary_from() { # <logfile> [<run-exit>]
  local sums line c last="" rexit="${2:-0}"
  sums=$(per_suite_summaries "$1")
  [ -n "$sums" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    last="$line"
    c=$(line_fail_count "$line")
    if [ "${c:-0}" -gt 0 ]; then printf '%s\n' "$line"; return 0; fi
  done <<EOF
$sums
EOF
  line=$(printf '%s\n' "$sums" | grep -E "$RED_RE" 2>/dev/null | head -1)
  [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
  # A red run whose failing suite printed nothing parseable: naming a passing
  # suite's line here would put a PASS beside EXIT=1. Say what happened instead.
  if [ "$rexit" != "0" ]; then printf 'no summary line (a suite failed without a parseable summary)\n'; return 0; fi
  printf '%s\n' "$last"
}
suites_from()  { [ -n "$SUITES_RE" ] || return 0; grep -E "$SUITES_RE" "$1" 2>/dev/null | tail -1; }
has_red_marker() { grep -qE "$RED_RE" "$1" 2>/dev/null; }

# The verdict for one reverted file. Green is the exit code; a red with a
# parseable count is a counted red; a red the grammar cannot count is still a
# red as long as the log SAYS so; only a run that died with no red marker at
# all is breakage rather than pin proof.
verdict_for() { # <file> <exit> <logfile> <n-suites> <restore-note>
  local vf="$1" ve="$2" vlog="$3" vn="$4" vr="$5" vtf vsl
  vtf=$(fail_count_from "$vlog"); vsl=$(summary_from "$vlog")
  if [ "$ve" -eq 0 ]; then
    echo "REVERT_STAYS_GREEN $vf: $vn suite(s) green with the change reverted — missing or degenerate pin (the seat ranks it) | ${vsl:-no summary line} | $vr"
  elif [ "$vtf" -gt 0 ]; then
    echo "REVERT_RED $vf: $vtf failure(s) across $vn suite(s) | ${vsl:-no summary line} | $vr"
  elif has_red_marker "$vlog"; then
    echo "REVERT_RED $vf: red (no count parsed) across $vn suite(s) | ${vsl:-no summary line} | $vr"
  else
    echo "REVERT_RED_BY_LOAD_FAILURE $vf: the run died with 0 reported failures and no red marker, so this is breakage, not pin proof (a consumer needs this file's new shape) | ${vsl:-no summary line} | $vr"
  fi
}

# ---------- 0 inventory -------------------------------------------------------
echo "== 0 inventory =="
# git's exit status is the difference between "nothing changed" and "I could not
# read this tree". Swallowing it turns an unreadable index into a green run.
git diff --name-only "$BASE" > "$RUNDIR/changed.raw" 2>/dev/null \
  || refuse "git could not read the copy (git diff --name-only $BASE failed)"
sort -u "$RUNDIR/changed.raw" > "$RUNDIR/changed.txt"
git ls-files --others --exclude-standard > "$RUNDIR/untracked.raw" 2>/dev/null \
  || refuse "git could not read the copy (git ls-files --others failed)"
sort -u "$RUNDIR/untracked.raw" > "$RUNDIR/untracked.txt"

PROD_TRACKED=(); TEST_CHANGED=(); PROD_NEW=(); PROD_DELETED=(); SYMLINKS=(); NONCOMMENT_LANG=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -L "$f" ]; then SYMLINKS+=("$f"); continue; fi
  if [ ! -e "$f" ]; then
    is_prod "$f" && PROD_DELETED+=("$f")
    continue
  fi
  [ -f "$f" ] || continue
  if is_test "$f"; then TEST_CHANGED+=("$f"); elif is_prod "$f"; then PROD_TRACKED+=("$f"); fi
done < "$RUNDIR/changed.txt"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -L "$f" ]; then SYMLINKS+=("$f"); continue; fi
  [ -f "$f" ] || continue
  if is_test "$f"; then TEST_CHANGED+=("$f"); elif is_prod "$f"; then PROD_NEW+=("$f"); fi
done < "$RUNDIR/untracked.txt"

echo "production changed (tracked): ${#PROD_TRACKED[@]}"
for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}"; do
  if comment_only "$f"; then echo "  COMMENT_ONLY $f"
  else echo "  $f"; in_lang "$f" && NONCOMMENT_LANG=1; fi
done
echo "production new (untracked): ${#PROD_NEW[@]}"
for f in "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do echo "  NEW_FILE $f"; in_lang "$f" && NONCOMMENT_LANG=1; done
echo "production deleted: ${#PROD_DELETED[@]}"
for f in "${PROD_DELETED[@]+"${PROD_DELETED[@]}"}"; do echo "  DELETED $f"; done
echo "tests changed or new: ${#TEST_CHANGED[@]}"
for f in "${TEST_CHANGED[@]+"${TEST_CHANGED[@]}"}"; do echo "  $f"; done
for f in "${SYMLINKS[@]+"${SYMLINKS[@]}"}"; do
  echo "SYMLINK $f: not reverted, not a control candidate (the gate never writes through a link)"
done

ALLFILES="$RUNDIR/allfiles.txt"
cat "$RUNDIR/changed.txt" "$RUNDIR/untracked.txt" | sort -u | while IFS= read -r f; do
  [ -n "$f" ] || continue
  { [ -L "$f" ] || [ -f "$f" ]; } && printf '%s\n' "$f"
done > "$ALLFILES"
sha_list "$ALLFILES" "$RUNDIR/sha_start.txt"

# ---------- 1 export sweep ----------------------------------------------------
echo "== 1 export sweep =="
NEWEXP=0
if [ -z "$EXPORT_PATTERN" ]; then
  echo "export sweep SKIPPED (no export_pattern in the config)"
else
  # Both sides are read the same way: declarations by the profile's pattern,
  # plus brace re-exports. Parsing the braces only on the new side makes a name
  # that WAS a re-export and is now gone invisible.
  export_names() { # <file>
    grep -oE "$EXPORT_PATTERN" "$1" 2>/dev/null
    tr '\n' ' ' < "$1" 2>/dev/null | grep -oE "export[[:space:]]+(type[[:space:]]+)?\{[^}]*\}" \
      | sed -E 's/export[[:space:]]+(type[[:space:]]+)?\{//; s/\}//' \
      | tr ',' '\n' \
      | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^.*[[:space:]]as[[:space:]]+//' \
      | grep -v '^$' | sed 's/^/re-export /'
  }
  for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}"; do
    in_lang "$f" || continue
    git show "$BASE:$f" > "$RUNDIR/base_blob" 2>/dev/null || : > "$RUNDIR/base_blob"
    export_names "$RUNDIR/base_blob" | sort -u > "$RUNDIR/exp_old"
    export_names "$f" | sort -u > "$RUNDIR/exp_new"
    comm -13 "$RUNDIR/exp_old" "$RUNDIR/exp_new" | grep -v '^$' > "$RUNDIR/exp_added"
    comm -23 "$RUNDIR/exp_old" "$RUNDIR/exp_new" | grep -v '^$' > "$RUNDIR/exp_removed"
    if [ -s "$RUNDIR/exp_added" ]; then
      NEWEXP=1
      echo "NEW_EXPORTS $f: $(sed -E 's/.*[[:space:]]//' "$RUNDIR/exp_added" | tr '\n' ';')"
      importers_of "$f" > "$RUNDIR/exp_cons"
      echo "  named by $(grep -c . "$RUNDIR/exp_cons" | tr -d ' ') suite(s): $(tr '\n' ' ' < "$RUNDIR/exp_cons")"
    fi
    if [ -s "$RUNDIR/exp_removed" ]; then
      NEWEXP=1
      echo "REMOVED_EXPORTS $f: $(sed -E 's/.*[[:space:]]//' "$RUNDIR/exp_removed" | tr '\n' ';')"
      while IFS= read -r decl; do
        sym=$(printf '%s' "$decl" | sed -E 's/.*[[:space:]]//')
        [ -n "$sym" ] || continue
        # A name that moved from a declaration to a re-export is not removed.
        if tr '\n' ' ' < "$f" | grep -qE "export[[:space:]]+(type[[:space:]]+)?\{[^}]*[^A-Za-z0-9_]${sym}[^A-Za-z0-9_][^}]*\}"; then
          echo "  $sym is still exported by re-export (not removed)"; continue
        fi
        grep -rlw -- "$sym" "${SRC_ROOTS[@]+"${SRC_ROOTS[@]}"}" 2>/dev/null | grep -v "^\./*$f$" | sort -u > "$RUNDIR/exp_refs"
        echo "  $sym still referenced by $(grep -c . "$RUNDIR/exp_refs" | tr -d ' ') file(s): $(tr '\n' ' ' < "$RUNDIR/exp_refs")"
      done < "$RUNDIR/exp_removed"
    fi
  done
  for f in "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do
    in_lang "$f" && echo "NEW_MODULE $f (no consumer can name it yet; informational)"
  done
  [ "$NEWEXP" -eq 0 ] && echo "no export set changed on a tracked production file"
fi

# ---------- 2 touched families ------------------------------------------------
echo "== 2 touched families =="
if [ "$RUNNER_UNKNOWN" = "1" ]; then
  echo "RUNNER_UNKNOWN: runner.profile '${PROFILE}' is not a shipped profile and runner.test_cmd is empty"
  echo "SKIPPED (RUNNER_UNKNOWN)"
  [ "$RC" -eq 0 ] && RC=3
else
  : > "$RUNDIR/fam.tmp"
  if [ -n "$FAMS" ]; then
    printf '%s\n' $FAMS >> "$RUNDIR/fam.tmp"
  else
    for f in "${TEST_CHANGED[@]+"${TEST_CHANGED[@]}"}"; do is_suite "$f" && printf '%s\n' "$f" >> "$RUNDIR/fam.tmp"; done
    for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}" "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do
      in_lang "$f" || continue
      importers_of "$f" >> "$RUNDIR/fam.tmp"
    done
  fi
  sort -u "$RUNDIR/fam.tmp" | grep -v '^$' > "$RUNDIR/families.txt"
  FAMILIES=(); while IFS= read -r t; do [ -n "$t" ] && FAMILIES+=("$t"); done < "$RUNDIR/families.txt"
  echo "families: ${#FAMILIES[@]}"
  for t in "${FAMILIES[@]+"${FAMILIES[@]}"}"; do echo "  $t"; done
  if [ ${#FAMILIES[@]} -gt 0 ]; then
    wait_for_quiet
    run_suites "$RUNDIR/families.log" "${FAMILIES[@]}"; E=$?
    FAMSUITES=""
    [ -n "$SUITES_RE" ] && FAMSUITES=" | $(suites_from "$RUNDIR/families.log")"
    echo "FAMILIES EXIT=$E failures=$(fail_count_from "$RUNDIR/families.log") | $(summary_from "$RUNDIR/families.log" "$E")${FAMSUITES} [$(elapsed)]"
  else
    echo "FAMILIES none found (no changed suite and no suite names a changed file) — the seat names the family"
  fi
fi

# ---------- 3 file-level revert-to-red ----------------------------------------
echo "== 3 file-level revert-to-red =="
if [ "$RUNNER_UNKNOWN" = "1" ]; then
  echo "SKIPPED (RUNNER_UNKNOWN)"
else
  for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}"; do
    if ! in_lang "$f"; then
      echo "NATIVE $f: its extension is outside the ${PROFILE} runner's language; the seat proves it by hand"
      continue
    fi
    if comment_only "$f"; then echo "COMMENT_ONLY $f: nothing to revert"; continue; fi
    if ! git cat-file -e "$BASE:$f" 2>/dev/null; then
      echo "NEW_FILE $f: absent at base (added since); file-level revert is not meaningful"
      continue
    fi
    b=$(basename "$f"); b="${b%.*}"
    : > "$RUNDIR/sub.tmp"
    for t in "${TEST_CHANGED[@]+"${TEST_CHANGED[@]}"}"; do
      is_suite "$t" || continue
      grep -q -- "$b" "$t" 2>/dev/null && printf '%s\n' "$t" >> "$RUNDIR/sub.tmp"
    done
    importers_of "$f" >> "$RUNDIR/sub.tmp"
    sort -u "$RUNDIR/sub.tmp" | grep -v '^$' > "$RUNDIR/subs.txt"
    SUBS=(); while IFS= read -r t; do [ -n "$t" ] && SUBS+=("$t"); done < "$RUNDIR/subs.txt"
    if [ ${#SUBS[@]} -eq 0 ]; then
      echo "REVERT_STAYS_GREEN $f: no suite names it and no changed suite mentions it — no pin covers this file (the seat ranks it)"
      continue
    fi
    keep="$RUNDIR/keep_$(printf '%s' "$f" | tr '/' '_')"
    cp "$f" "$keep"
    printf '%s\n%s\n' "$keep" "$f" > "$RUNDIR/active_revert"
    git show "$BASE:$f" > "$f"
    wait_for_quiet
    log="$RUNDIR/revert_$(printf '%s' "$f" | tr '/' '_').log"
    run_suites "$log" "${SUBS[@]}"; E=$?
    cp "$keep" "$f"
    if cmp -s "$keep" "$f"; then R="restored cmp-identical"; else R="RESTORE_FAILED"; RC=4; fi
    rm -f "$RUNDIR/active_revert"
    verdict_for "$f" "$E" "$log" "${#SUBS[@]}" "$R"
  done
  # A deletion is a change like any other: put the file back, run what names it,
  # then take it away again. A deletion nobody's suite notices stays green here,
  # which is the same finding as an unpinned edit.
  for f in "${PROD_DELETED[@]+"${PROD_DELETED[@]}"}"; do
    if ! in_lang "$f"; then
      echo "NATIVE $f (deleted): its extension is outside the ${PROFILE} runner's language; the seat proves it by hand"
      continue
    fi
    if ! git cat-file -e "$BASE:$f" 2>/dev/null; then
      echo "DELETED $f: absent at base as well; nothing to restore"
      continue
    fi
    b=$(basename "$f"); b="${b%.*}"
    : > "$RUNDIR/sub.tmp"
    for t in "${TEST_CHANGED[@]+"${TEST_CHANGED[@]}"}"; do
      is_suite "$t" || continue
      grep -q -- "$b" "$t" 2>/dev/null && printf '%s\n' "$t" >> "$RUNDIR/sub.tmp"
    done
    importers_of "$f" >> "$RUNDIR/sub.tmp"
    sort -u "$RUNDIR/sub.tmp" | grep -v '^$' > "$RUNDIR/subs.txt"
    SUBS=(); while IFS= read -r t; do [ -n "$t" ] && SUBS+=("$t"); done < "$RUNDIR/subs.txt"
    if [ ${#SUBS[@]} -eq 0 ]; then
      echo "REVERT_STAYS_GREEN $f: no suite names it and no changed suite mentions it — no pin covers this deletion (the seat ranks it)"
      continue
    fi
    printf '%s\n' "$f" > "$RUNDIR/active_deleted"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    git show "$BASE:$f" > "$f"
    wait_for_quiet
    log="$RUNDIR/revert_$(printf '%s' "$f" | tr '/' '_').log"
    run_suites "$log" "${SUBS[@]}"; E=$?
    rm -f "$f"
    if [ -e "$f" ]; then R="RESTORE_FAILED"; RC=4; else R="deletion restored"; fi
    rm -f "$RUNDIR/active_deleted"
    verdict_for "$f" "$E" "$log" "${#SUBS[@]}" "$R"
  done
  for f in "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do
    echo "NEW_FILE $f: file-level revert is not meaningful; the seat proves its mechanisms by hunk"
  done
fi

# ---------- 4 typecheck + positive control ------------------------------------
echo "== 4 typecheck =="
do_typecheck() { # <logfile>
  local log="$1" rc=0 f
  : > "$log"
  if [ -n "$TYPECHECK_CMD" ]; then
    ( spawn_env; eval "$TYPECHECK_CMD" ) >> "$log" 2>&1
    return $?
  fi
  if [ "$PROFILE" = "shell-suites" ]; then
    for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}" "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do
      case "$f" in *.sh) echo "--- bash -n $f" >> "$log"; bash -n "$f" >> "$log" 2>&1 || rc=1 ;; esac
    done
    return $rc
  fi
  return 127
}

if [ "$NO_TYPECHECK" = "1" ]; then
  echo "TYPECHECK_SKIPPED (--no-typecheck)"
elif [ "$NONCOMMENT_LANG" -eq 0 ]; then
  echo "TYPECHECK_SKIPPED (no non-comment production change in the runner's language)"
elif [ -z "$TYPECHECK_CMD" ] && [ "$PROFILE" != "shell-suites" ]; then
  echo "TYPECHECK_SKIPPED (no typecheck_cmd in the config)"
else
  wait_for_quiet
  do_typecheck "$RUNDIR/typecheck.log"; E=$?
  echo "TYPECHECK EXIT=$E markers=$(grep -c "${PC_MARKER:-error}" "$RUNDIR/typecheck.log" | tr -d ' ') [$(elapsed)] log=$RUNDIR/typecheck.log"
  CF=""
  if [ -n "$PC_EXT" ] && [ -n "$PC_SNIPPET" ]; then
    for f in "${PROD_TRACKED[@]+"${PROD_TRACKED[@]}"}" "${PROD_NEW[@]+"${PROD_NEW[@]}"}"; do
      [ -L "$f" ] && continue
      case "$f" in *"$PC_EXT") CF="$f"; break ;; esac
    done
  fi
  if [ -n "$CF" ]; then
    cp "$CF" "$RUNDIR/control.bak"
    printf '%s\n%s\n' "$RUNDIR/control.bak" "$CF" > "$RUNDIR/active_control"
    printf '\n%s\n' "$PC_SNIPPET" >> "$CF"
    wait_for_quiet
    do_typecheck "$RUNDIR/typecheck_control.log"; E=$?
    echo "TYPECHECK_CONTROL($CF) EXIT=$E markers=$(grep -c "${PC_MARKER:-error}" "$RUNDIR/typecheck_control.log" | tr -d ' ') [$(elapsed)]"
    grep -m2 -- "$PC_MARKER" "$RUNDIR/typecheck_control.log" | sed 's/^/  /'
    if ! grep -q -- "$PC_MARKER" "$RUNDIR/typecheck_control.log"; then
      echo "CONTROL_DID_NOT_FIRE: the injected control produced no '$PC_MARKER' — the typecheck proves nothing"
      [ "$RC" -eq 0 ] && RC=4
    fi
    cp "$RUNDIR/control.bak" "$CF"
    if cmp -s "$RUNDIR/control.bak" "$CF"; then echo "CONTROL_RESTORED cmp-identical"
    else echo "CONTROL_RESTORE_FAILED $CF"; RC=4; fi
    rm -f "$RUNDIR/active_control"
  else
    echo "TYPECHECK_CONTROL skipped (no changed production file with extension '${PC_EXT}')"
  fi
  if [ -n "$UNUSED_CMD" ]; then
    wait_for_quiet
    ( spawn_env; eval "$UNUSED_CMD" ) > "$RUNDIR/unused.log" 2>&1
    echo "UNUSED EXIT=$? [$(elapsed)] log=$RUNDIR/unused.log"
  fi
fi

exit $RC
