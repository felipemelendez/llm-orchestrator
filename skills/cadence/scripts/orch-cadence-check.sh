#!/usr/bin/env bash
# orch-cadence-check.sh — read, write and enforce the cadence lock.
#
# WHAT
#   --verdict                 one line, <= 300 chars, on stdout: whether cadence
#                             mode is on, the laws' highest ruling, and whether
#                             the lock still matches the tree. Always exit 0.
#   --lock                    (re)write docs/llm-orchestrator/LOCK.sha256. The
#                             only writer of that file.
#   --landing <ticket>        the evidence check for a ticket's five reports.
#     [--base <sha>]
#   --commit-msg <msgfile>    the git-side gate (git hands the message file to
#                             commit-msg, and to no other hook).
#   --audit <rev>             the same three checks against a commit, for CI.
#   --version                 print the version this copy carries.
#   --root <dir>              use <dir> as the project root instead of resolving
#                             it (git toplevel of $PWD, else CLAUDE_PROJECT_DIR,
#                             else $PWD).
#
# WHY
#   The laws of a project are only laws while they cannot be edited quietly. The
#   lock is a content manifest: whole files for the four the cadence owns, and
#   the marked SECTION of CLAUDE.md / AGENTS.md so the rest of both files stays
#   writable. The verdict REPORTS — a session-start line and a stop-hook note
#   call it, so it never blocks and never costs more than a moment. Refusing is
#   the git layer's job, at commit-msg, where the message can carry a ruling.
#
# EXIT CODES
#   0  all good (and always, for --verdict)
#   1  a refusal, a defect, or a usage error — the contract is 0/1 and nothing
#      else, so nobody has to wonder what a 2 from a hook means
#
# NOTES
#   python3 is a SOFT dependency: scalar config keys are read with sed when it is
#   absent OR present-but-failing (a pyenv shim with no version, a stub), so
#   --verdict and --commit-msg stay correct; ARRAY keys (lock_extra) are empty in
#   that case and ONE note goes to stderr per invocation. Set
#   ORCH_CADENCE_PYTHON to point at another interpreter (or at a path that does
#   not exist, to exercise the python-free path).
#   The git layer decides cadence on/off from GIT, never from the working tree:
#   --commit-msg reads the config staged in the index and the one at HEAD (on if
#   either is on), --audit reads it at the revision. A config that is present but
#   does not decode is ON there — the gate fails closed. Only --verdict reports
#   on the working tree, and it says so when that copy differs from HEAD.
#   Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.  # portable-ok

set -uo pipefail
LC_ALL=C
export LC_ALL

ORCH_CADENCE_CHECK_VERSION="0.8.0"

SEC_START='<!-- ORCH:LAWS:START -->'
SEC_END='<!-- ORCH:LAWS:END -->'
LOCK_REL='docs/llm-orchestrator/LOCK.sha256'
LAWS_REL='docs/llm-orchestrator/LAWS.md'
CFG_REL='docs/llm-orchestrator/cadence.json'
MAX_HASHED=64
MAX_NAMED=5

PY="${ORCH_CADENCE_PYTHON:-python3}"

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

usage() {
  echo "usage: orch-cadence-check.sh [--root <dir>] --verdict | --lock | --landing <ticket> [--base <sha>] | --commit-msg <msgfile> | --audit <rev> | --version"
}

# ---------- hashing -----------------------------------------------------------
# sha256 with a fallback chain: no single tool is present everywhere.
sha_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else echo "NO_SHA256_TOOL" >&2; return 1; fi
}
sha_file() { sha_stdin < "$1"; }

# ---------- config ------------------------------------------------------------
CFG_FILE=""
CFG_LOADED=0
CFG_OK=0
CFG_DUMP=""
CFG_SEQ=0
# The note has to survive a pipeline: lock_entries reads the array inside one,
# and a variable set there dies with the subshell. A marker file does not.
CFG_NOTE_MARK="$TMPD/cfg.noted"

cfg_note() { # <text> — at most one note per invocation
  [ -f "$CFG_NOTE_MARK" ] && return 0
  : > "$CFG_NOTE_MARK"
  echo "note: $1" >&2
}

cfg_use() { # <file> — read a different config (an index or HEAD blob) from here on
  CFG_FILE="$1"; CFG_LOADED=0; CFG_OK=0; CFG_DUMP=""
}

cfg_load() {
  [ "$CFG_LOADED" = "1" ] && return 0
  CFG_LOADED=1
  CFG_SEQ=$((CFG_SEQ + 1))
  CFG_DUMP="$TMPD/cfg.dump.$CFG_SEQ"; : > "$CFG_DUMP"
  [ -f "$CFG_FILE" ] || return 0
  if command -v "$PY" >/dev/null 2>&1; then
    "$PY" - "$CFG_FILE" > "$CFG_DUMP" 2>/dev/null <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
def emit(k, v):
    if isinstance(v, list):
        for x in v:
            print("A\t%s\t%s" % (k, x))
    elif isinstance(v, dict):
        for kk, vv in v.items():
            emit(k + "." + kk, vv)
    elif isinstance(v, bool):
        print("B\t%s\t%s" % (k, "true" if v else "false"))
    elif v is None:
        print("S\t%s\t" % k)
    else:
        print("S\t%s\t%s" % (k, v))
for k, v in d.items():
    emit(k, v)
PYEOF
    if [ $? -eq 0 ]; then
      CFG_OK=1
    else
      # The interpreter ran and failed (a shim, a stub, a broken install). That
      # is not "no config": fall through to the same sed path python3's ABSENCE
      # takes, so a broken interpreter can never read as "cadence: off".
      : > "$CFG_DUMP"
      cfg_structural_ok
      cfg_note "python3 is unavailable ($PY did not run); array config keys (lock_extra) read as empty"
    fi
  else
    cfg_structural_ok
  fi
  return 0
}

# No usable interpreter: a cheap structural sanity check stands in for a parse.
cfg_structural_ok() {
  case "$(tr -d '[:space:]' < "$CFG_FILE" | cut -c1)" in
    '{') CFG_OK=1 ;;
    *)   CFG_OK=0 ;;
  esac
}

# A JSON boolean, and nothing else. "true" the STRING is not true: a config that
# spells it with quotes is a config nobody has read, and reading it as ON is how
# a typo arms — or disarms — a project silently.
cfg_bool() { # <key> — rc 0 when the key is the boolean true
  cfg_load
  if [ -n "$CFG_DUMP" ] && [ -s "$CFG_DUMP" ]; then
    [ "$(awk -F'\t' -v k="$1" '$1=="B" && $2==k {print $3; exit}' "$CFG_DUMP")" = "true" ] && return 0
    return 1
  fi
  [ -f "$CFG_FILE" ] || return 1
  grep -qE "\"$1\"[[:space:]]*:[[:space:]]*true([[:space:],}]|$)" "$CFG_FILE" 2>/dev/null
}

cfg_scalar() { # <key>  (dotted for nested)
  cfg_load
  if [ -n "$CFG_DUMP" ] && [ -s "$CFG_DUMP" ]; then
    awk -F'\t' -v k="$1" '($1=="S" || $1=="B") && $2==k {print $3; found=1; exit} END{if(!found) exit 1}' "$CFG_DUMP" && return 0
  fi
  [ -f "$CFG_FILE" ] || return 1
  local k v
  k="${1##*.}"
  # sed -E: BSD sed has no \| alternation, so the scalar fallback must be ERE.
  v=$(sed -n -E "s/.*\"${k}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\\1/p" "$CFG_FILE" | head -1)
  if [ -z "$v" ]; then
    v=$(sed -n -E "s/.*\"${k}\"[[:space:]]*:[[:space:]]*(true|false|-?[0-9][0-9.]*).*/\\1/p" "$CFG_FILE" | head -1)
  fi
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

cfg_array() { # <key> — one element per line
  cfg_load
  if [ -n "$CFG_DUMP" ] && [ -s "$CFG_DUMP" ]; then
    awk -F'\t' -v k="$1" '$1=="A" && $2==k {print $3}' "$CFG_DUMP"
    return 0
  fi
  if ! command -v "$PY" >/dev/null 2>&1; then
    cfg_note "python3 is unavailable; array config keys (lock_extra) read as empty"
  fi
  return 0
}

# ---------- root and mode -----------------------------------------------------
OPT_ROOT=""
ROOT_DIR=""

resolve_root() {
  if [ -n "$OPT_ROOT" ]; then
    ROOT_DIR="$OPT_ROOT"
  else
    local t
    t=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$t" ] && [ -d "$t" ]; then ROOT_DIR="$t"
    elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then ROOT_DIR="$CLAUDE_PROJECT_DIR"
    else ROOT_DIR="$PWD"; fi
  fi
  ROOT_DIR="${ROOT_DIR%/}"
  CFG_FILE="$ROOT_DIR/$CFG_REL"
}

cadence_on() { # 0 = on
  [ -f "$CFG_FILE" ] || return 1
  cfg_load
  [ "$CFG_OK" = "1" ] || return 1
  cfg_bool enabled || return 1
  return 0
}

# ---------- the git side's mode ----------------------------------------------
# The working tree is not evidence at commit time: an agent can write
# enabled:false into it, or delete it, without staging anything. Mode comes from
# the config being COMMITTED and the one at HEAD; either one enabled arms the
# gate, and a copy that is present but does not decode arms it too (fail
# closed). The chosen blob then serves ticket_re, notes_dir and lock_extra, so
# the revision is graded with the revision's own config.
# rc 0 = on (CFG_FILE now points at the blob), 1 = off, 2 = cannot decide.
git_mode() { # <index-ref-prefix> <head-ref-prefix>
  local pref blob n=0 present=0 on=0 bad=0 chosen=""
  for pref in "$1" "$2"; do
    n=$((n + 1))
    blob="$TMPD/gitcfg.$n"
    git -C "$ROOT_DIR" show "${pref}${CFG_REL}" > "$blob" 2>/dev/null || { rm -f "$blob"; continue; }
    present=1
    cfg_use "$blob"; cfg_load
    if [ "$CFG_OK" != "1" ]; then bad=1; continue; fi
    if cfg_bool enabled; then on=1; [ -n "$chosen" ] || chosen="$blob"; fi
  done
  if [ "$on" = "1" ]; then cfg_use "$chosen"; return 0; fi
  [ "$bad" = "1" ] && return 2
  [ "$present" = "1" ] && return 1
  return 1
}

unlock_env() { [ "${ORCH_CADENCE_UNLOCK:-}" = "1" ]; }

settings_carrying_unlock() { # prints the first settings file that persists the token
  local f
  for f in "$ROOT_DIR/.claude/settings.json" "$ROOT_DIR/.claude/settings.local.json" "${HOME:-/nonexistent}/.claude/settings.json"; do
    [ -f "$f" ] || continue
    if grep -q 'ORCH_CADENCE_UNLOCK' "$f" 2>/dev/null; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# ---------- the marked section ------------------------------------------------
# The FIRST start marker through the first end marker after it. Never the last
# block: a second, decoy pair would otherwise let an edit hide in the first one.
# "Started and never ended" is NOT "this file has no section". Collapsing the
# two drops the law out of the lock set silently: the manifest is written
# without it, the verdict reads OK, and the text inside the section can then be
# rewritten under any message. It gets a state of its own, handled everywhere
# the duplicate-marker state is.
section_of_file() { # <file> -> stdout; rc 0 ok, 1 no section, 2 duplicate start, 3 unterminated, 4 orphan end
  local f="$1" n ne out rc
  [ -f "$f" ] || return 1
  n=$(grep -o -- "$SEC_START" "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 1 ] && return 2
  # An END marker that no START opened is the mirror of "started, never ended":
  # counting only START markers would read it as "no section", write the
  # manifest without the entry, and let the text above the marker be rewritten.
  if [ "${n:-0}" -eq 0 ]; then
    ne=$(grep -o -- "$SEC_END" "$f" 2>/dev/null | wc -l | tr -d ' ')
    [ "${ne:-0}" -gt 0 ] && return 4
    return 1
  fi
  out=$(awk -v s="$SEC_START" -v e="$SEC_END" '
    !p && index($0, s) { p=1; print; if (index($0, e)) { d=1; exit } ; next }
    p { print; if (index($0, e)) { d=1; exit } }
    END { if (!d) exit 3 }' "$f")
  rc=$?
  [ "$rc" -eq 3 ] && return 3
  [ "$rc" -ne 0 ] && return 1
  printf '%s\n' "$out"
  return 0
}

# ---------- the lock set ------------------------------------------------------
# The set the cadence owns whatever the config says. These are never capped and
# never dropped: a cap that can push LAWS.md out of the hashed set is a lock
# that reports OK on an edited law.
fixed_entries() {
  printf '%s\n' \
    "$LAWS_REL" \
    "$CFG_REL" \
    ".claude/settings.json" \
    ".githooks/commit-msg" \
    ".githooks/orch-cadence-check.sh" \
    "CLAUDE.md#ORCH:LAWS" \
    "AGENTS.md#ORCH:LAWS"
}

lock_entries() { # one entry per line, sorted, de-duplicated
  { fixed_entries; cfg_array lock_extra; } | grep -v '^$' | sort -u
}

# entry_hash_wt <entry> -> sha on stdout; rc 1 absent, 2 duplicate marker,
# 3 unterminated section
entry_hash_wt() {
  local e="$1" p sect rc
  case "$e" in
    *'#ORCH:LAWS')
      p="$ROOT_DIR/${e%'#ORCH:LAWS'}"
      sect=$(section_of_file "$p"); rc=$?
      [ "$rc" -eq 4 ] && return 4
      [ "$rc" -eq 3 ] && return 3
      [ "$rc" -eq 2 ] && return 2
      [ "$rc" -ne 0 ] && return 1
      printf '%s' "$sect" | sha_stdin
      ;;
    *)
      p="$ROOT_DIR/$e"
      [ -f "$p" ] || return 1
      sha_file "$p"
      ;;
  esac
  return 0
}

# entry_hash_ref <ref-prefix> <entry>; ref-prefix is ":" or "<rev>:" or "HEAD:"
entry_hash_ref() {
  local pref="$1" e="$2" p blob sect rc
  blob="$TMPD/blob.$$"
  case "$e" in
    *'#ORCH:LAWS')
      p="${e%'#ORCH:LAWS'}"
      git -C "$ROOT_DIR" show "${pref}${p}" > "$blob" 2>/dev/null || return 1
      sect=$(section_of_file "$blob"); rc=$?
      [ "$rc" -eq 4 ] && return 4
      [ "$rc" -eq 3 ] && return 3
      [ "$rc" -eq 2 ] && return 2
      [ "$rc" -ne 0 ] && return 1
      printf '%s' "$sect" | sha_stdin
      ;;
    *)
      git -C "$ROOT_DIR" show "${pref}${e}" > "$blob" 2>/dev/null || return 1
      sha_file "$blob"
      ;;
  esac
  return 0
}

lock_line_for() { # <lockfile> <entry> -> the recorded sha, or empty
  awk -v e="$2" '{ if (substr($0, 67) == e) { print substr($0, 1, 64); exit } }' "$1" 2>/dev/null
}

highest_ruling_in() { # <file-or-empty-stdin-file> -> the number, or empty
  [ -f "$1" ] || return 1
  grep -oE 'Ruling [0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1
}

# ---------- modes -------------------------------------------------------------
mode_verdict() {
  local line laws ruling lockf state changed hashed ehashed unhashed e h rec rc
  laws="$ROOT_DIR/$LAWS_REL"
  if ! cadence_on; then
    if [ ! -f "$CFG_FILE" ] && [ -f "$laws" ]; then
      echo "cadence: LAWS.md present, cadence.json absent — run /llm-orchestrator:cadence-init"
    else
      echo "cadence: off"
    fi
    return 0
  fi
  if [ -f "$laws" ]; then
    ruling=$(highest_ruling_in "$laws")
    [ -n "$ruling" ] || ruling="—"
    line="cadence: LAWS.md (ruling ${ruling})"
  else
    line="cadence: LAWS.md absent"
  fi
  lockf="$ROOT_DIR/$LOCK_REL"
  if [ ! -f "$lockf" ]; then
    line="$line · lock UNARMED"
  else
    # The union of "what the lock records" and "what the lock set is now": an
    # entry that appeared or vanished since the lock is a change either way.
    # The fixed set and every path the manifest records are ALWAYS hashed; the
    # 64 cap bounds the project's own lock_extra and nothing else.
    # A manifest that came back through a CRLF editor still records the same
    # paths: a trailing CR is line ending, not part of the entry name.
    { fixed_entries; awk '{ sub(/\r$/, ""); print substr($0, 67) }' "$lockf"; } | grep -v '^$' | sort -u > "$TMPD/always"
    { lock_entries; awk '{ sub(/\r$/, ""); print substr($0, 67) }' "$lockf"; } | grep -v '^$' | sort -u > "$TMPD/union"
    comm -13 "$TMPD/always" "$TMPD/union" > "$TMPD/extras"
    cat "$TMPD/always" "$TMPD/extras" > "$TMPD/ordered"
    hashed=0; ehashed=0; unhashed=0; changed=""
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      if grep -qxF -- "$e" "$TMPD/extras"; then
        if [ "$ehashed" -ge "$MAX_HASHED" ]; then unhashed=$((unhashed + 1)); continue; fi
        ehashed=$((ehashed + 1))
      fi
      hashed=$((hashed + 1))
      rec=$(lock_line_for "$lockf" "$e")
      h=$(entry_hash_wt "$e"); rc=$?
      if [ "$rc" -eq 2 ]; then
        changed="${changed}${e} (duplicate marker),"
      elif [ "$rc" -eq 3 ]; then
        changed="${changed}${e} (unterminated section),"
      elif [ "$rc" -eq 4 ]; then
        changed="${changed}${e} (orphan end marker),"
      elif [ "$rc" -ne 0 ]; then
        [ -n "$rec" ] && changed="${changed}${e},"
      else
        if [ -z "$rec" ] || [ "$rec" != "$h" ]; then changed="${changed}${e},"; fi
      fi
    done < "$TMPD/ordered"
    changed="${changed%,}"
    if [ -z "$changed" ]; then
      state="OK"
    else
      local shown=0 acc="" more=0 p
      local old_ifs="$IFS"; IFS=','
      for p in $changed; do
        if [ "$shown" -lt "$MAX_NAMED" ]; then acc="${acc}${p},"; shown=$((shown + 1)); else more=$((more + 1)); fi
      done
      IFS="$old_ifs"
      acc="${acc%,}"
      state="CHANGED ${acc}"
      [ "$more" -gt 0 ] && state="$state +${more}"
    fi
    [ "$unhashed" -gt 0 ] && state="$state +${unhashed} extras unhashed"
    line="$line · lock $state"
  fi
  # The verdict reports on what the session sees, which is the working tree. If
  # that copy of the config is not the one HEAD carries, the reader has to know:
  # the git layer will grade the commit with HEAD's, not with this one.
  if git -C "$ROOT_DIR" show "HEAD:$CFG_REL" > "$TMPD/headcfg" 2>/dev/null; then
    cmp -s "$TMPD/headcfg" "$CFG_FILE" || line="$line · config differs from HEAD"
  fi
  unlock_env && line="$line · UNLOCKED"
  # The skips a session has applied, when the session has a state file to
  # record them in. With no state file the verdict line is unchanged byte for
  # byte — a fresh project must not be told "skips: 0" on its first turn.
  local sdir sfile
  sdir=$(cfg_scalar notes_dir); [ -n "$sdir" ] || sdir="docs/llm-orchestrator/notes"
  sfile="$ROOT_DIR/$sdir/CADENCE_STATE.md"
  if [ -f "$sfile" ]; then
    line="$line · skips: $(live_skips "$sfile")"
  fi
  printf '%s\n' "${line:0:300}"
  return 0
}

# A skip is live until a later `re-armed:` or `expired:` line names the SAME
# stage and the SAME class. Counting every `skip:` line reported skips that had
# already been cancelled, which is the opposite of what the number is for.
live_skips() { # <state file>
  awk '
    function key(l,   stage, cls) {
      sub(/^[a-z-]+:[[:space:]]*/, "", l)
      stage = l; sub(/[[:space:]]*\xc2\xb7.*$/, "", stage)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", stage)
      cls = ""
      if (match(l, /class[[:space:]]+[A-Za-z0-9_-]+/)) {
        cls = substr(l, RSTART, RLENGTH); sub(/^class[[:space:]]+/, "", cls)
      }
      return stage "\034" cls
    }
    /^skip:/            { k = key($0); n[k]++; next }
    /^re-armed:|^expired:/ { k = key($0); n[k] = 0; next }
    END { t = 0; for (k in n) t += n[k]; print t }
  ' "$1" 2>/dev/null || printf '0'
}

mode_lock() {
  local sf e h rc out
  if ! cadence_on; then
    echo "cadence: off in $ROOT_DIR — --lock needs $CFG_REL with \"enabled\": true"
    return 1
  fi
  if sf=$(settings_carrying_unlock); then
    echo "REFUSED: $sf carries ORCH_CADENCE_UNLOCK — a persisted unlock is a disarmed lock; remove it, then re-run --lock"
    return 1
  fi
  if [ -f "$ROOT_DIR/$LOCK_REL" ] && ! unlock_env; then
    echo "REFUSED: $LOCK_REL already exists; re-run with ORCH_CADENCE_UNLOCK=1 in the environment to rewrite it"
    return 1
  fi
  out="$TMPD/lock.new"; : > "$out"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    h=$(entry_hash_wt "$e"); rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "REFUSED: ${e} has a second $SEC_START marker (duplicate marker); one pair per file"
      return 1
    fi
    if [ "$rc" -eq 3 ]; then
      echo "REFUSED: ${e} has $SEC_START with no matching $SEC_END (unterminated section); close the section, then re-run --lock"
      return 1
    fi
    if [ "$rc" -eq 4 ]; then
      echo "REFUSED: ${e} has $SEC_END with no $SEC_START before it (orphan end marker); open the section, then re-run --lock"
      return 1
    fi
    [ "$rc" -ne 0 ] && continue
    printf '%s  %s\n' "$h" "$e" >> "$out"
  done < <(lock_entries)
  sort -k2,2 "$out" > "$ROOT_DIR/$LOCK_REL" || return 1
  echo "lock written: $(grep -c . "$ROOT_DIR/$LOCK_REL" | tr -d ' ') entries in $LOCK_REL"
  return 0
}

# base_date <rev> -> the commit's author date as YYYY-MM-DD HH:MM:SS, in the
# LOCAL zone. The evidence stamps are written by `date` on the machine running
# the seats; rendering the commit in the AUTHOR's zone compares two different
# clocks, which passes stale evidence from one direction and rejects fresh
# evidence from the other.
base_date() {
  git -C "$ROOT_DIR" log -1 --format=%ad --date=format-local:'%Y-%m-%d %H:%M:%S' "$1" 2>/dev/null
}

# mode_landing <ticket> <base> [<rev-ref-prefix>]
# With a ref prefix the evidence is read AT that revision (git show), so an
# audit grades the commit with the files the commit carried, not with whatever
# the working tree holds today.
mode_landing() {
  local ticket="$1" base="$2" pref="${3:-}" nd bts defects f r ts fin
  if [ -z "$pref" ] && ! cadence_on; then
    echo "cadence: off in $ROOT_DIR — --landing needs $CFG_REL with \"enabled\": true"
    return 1
  fi
  nd=$(cfg_scalar notes_dir); [ -n "$nd" ] || nd="docs/llm-orchestrator/notes"
  bts=$(base_date "$base")
  if [ -z "$bts" ]; then
    echo "LANDING $ticket: cannot read the author date of base $base"
    return 1
  fi
  defects=0
  for r in BRIEFREV REV1 REV2 REFUTE GATE; do
    if [ -n "$pref" ]; then
      f="$TMPD/evidence_${r}.md"
      git -C "$ROOT_DIR" show "${pref}${nd}/${ticket}_${r}_report.md" > "$f" 2>/dev/null || rm -f "$f"
    else
      f="$ROOT_DIR/$nd/${ticket}_${r}_report.md"
    fi
    if [ ! -f "$f" ]; then
      echo "LANDING $ticket: missing ${nd}/${ticket}_${r}_report.md"
      defects=$((defects + 1)); continue
    fi
    ts=$(grep -oE 'Started: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$f" | head -1 | sed 's/^Started: //')
    if [ -z "$ts" ]; then
      echo "LANDING $ticket: ${ticket}_${r}_report.md has no Started: YYYY-MM-DD HH:MM:SS stamp"
      defects=$((defects + 1))
    elif [ ! "$ts" \> "$bts" ]; then
      echo "LANDING $ticket: ${ticket}_${r}_report.md Started $ts is not later than the base commit ($bts) — stale evidence"
      defects=$((defects + 1))
    fi
    fin=$(grep -oE 'Finished: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$f" | tail -1 | sed 's/^Finished: //')
    if [ -z "$fin" ]; then
      echo "LANDING $ticket: ${ticket}_${r}_report.md has no Finished: YYYY-MM-DD HH:MM:SS stamp"
      defects=$((defects + 1))
    elif [ ! "$fin" \> "$bts" ]; then
      echo "LANDING $ticket: ${ticket}_${r}_report.md Finished $fin is not later than the base commit ($bts) — stale evidence"
      defects=$((defects + 1))
    fi
    if [ "$r" = "GATE" ] && [ "$(tail -n 1 "$f")" != "EXIT=0" ]; then
      echo "LANDING $ticket: ${ticket}_${r}_report.md last line is not EXIT=0"
      defects=$((defects + 1))
    fi
  done
  if [ "$defects" -gt 0 ]; then return 1; fi
  echo "LANDING $ticket: OK (5 reports, all finished after $bts)"
  return 0
}

# git_lock_entries <index-ref-prefix> <head-ref-prefix> <outfile>
# The set the git layer enforces: the fixed entries, the config's lock_extra
# when it can be read, AND every path the staged or HEAD manifest records. The
# manifest half matters most where the config half is weakest — without python3
# lock_extra reads as empty, and an entry that only the manifest knows about
# would otherwise walk out of the commit-msg gate while the verdict still
# reports it CHANGED.
git_lock_entries() {
  { lock_entries
    git -C "$ROOT_DIR" show "${1}${LOCK_REL}" 2>/dev/null | awk '{ sub(/\r$/, ""); if (length($0) > 66) print substr($0, 67) }'
    git -C "$ROOT_DIR" show "${2}${LOCK_REL}" 2>/dev/null | awk '{ sub(/\r$/, ""); if (length($0) > 66) print substr($0, 67) }'
  } | grep -v '^$' | sort -u > "$3"
}

# git_gate <index-ref-prefix> <head-ref-prefix> <message-file> <label> <landing-base>
# The three checks of the git layer, shared by --commit-msg and --audit.
git_gate() {
  local ipref="$1" hpref="$2" msgf="$3" label="$4" lbase="$5"
  local defects=0 lockblob e hi hh rec rc rch changed=0 subject tre tid n headlaws hr staged_laws
  local need_ruling=0 need_relock=0 armed_at_head=0 armed_in_index=0 entries="$TMPD/gitentries"
  git_lock_entries "$ipref" "$hpref" "$entries"
  git -C "$ROOT_DIR" show "${hpref}${LOCK_REL}" > "$TMPD/headlock" 2>/dev/null && armed_at_head=1
  lockblob="$TMPD/lockblob"
  if ! git -C "$ROOT_DIR" show "${ipref}${LOCK_REL}" > "$lockblob" 2>/dev/null; then
    if [ "$armed_at_head" = "1" ]; then
      # The manifest itself is part of what the lock protects: removing it under
      # a tidy-up message disarms the project for every commit after it.
      echo "$label: $LOCK_REL is at HEAD but not in the tree being committed — removing the manifest is a lock-set change"
      changed=1
    else
      echo "$label: no $LOCK_REL at this revision — the lock is unarmed; run --lock"
    fi
  else
    armed_in_index=1
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      rec=$(lock_line_for "$lockblob" "$e")
      hi=$(entry_hash_ref "$ipref" "$e"); rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "$label: $e has a second $SEC_START marker (duplicate marker)"
        defects=$((defects + 1)); continue
      fi
      if [ "$rc" -eq 3 ]; then
        echo "$label: $e has $SEC_START with no matching $SEC_END (unterminated section)"
        defects=$((defects + 1)); continue
      fi
      if [ "$rc" -eq 4 ]; then
        echo "$label: $e has $SEC_END with no $SEC_START before it (orphan end marker)"
        defects=$((defects + 1)); continue
      fi
      if [ "$rc" -ne 0 ]; then
        if [ -n "$rec" ]; then
          echo "$label: $e is in $LOCK_REL but absent from the tree being committed"
          defects=$((defects + 1)); need_relock=1
        fi
        continue
      fi
      if [ -z "$rec" ]; then
        echo "$label: $e is present but $LOCK_REL does not record it"
        defects=$((defects + 1)); need_relock=1
      elif [ "$rec" != "$hi" ]; then
        echo "$label: $e does not match the $LOCK_REL being committed (a stale lock cannot ride along)"
        defects=$((defects + 1)); need_relock=1
      fi
    done < "$entries"
  fi

  # 2 — did any lock-set entry change against the parent?
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    hi=$(entry_hash_ref "$ipref" "$e"); rc=$?
    hh=$(entry_hash_ref "$hpref" "$e"); rch=$?
    if [ "$rc" -ne "$rch" ] || [ "$hi" != "$hh" ]; then
      changed=1
      echo "$label: $e changed in this commit"
    fi
  done < "$entries"

  # A project with no manifest at HEAD is not yet under the lock, so the commit
  # that brings one needs no ruling — there is no law it could be amending. The
  # staged manifest is still checked against the staged content above, so an
  # arming commit cannot arm a project with a lock that already lies.
  if [ "$armed_at_head" = "0" ]; then
    [ "$armed_in_index" = "1" ] && echo "$label: cadence: arming this project (first lock commit)"
    changed=0
  fi

  if [ "$changed" = "1" ]; then
    n=$(grep -oE 'Ruling [0-9]+' "$msgf" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    if [ -z "$n" ]; then
      echo "$label: the message carries no numbered ruling"
      defects=$((defects + 1)); need_ruling=1
    else
      headlaws="$TMPD/headlaws"
      if git -C "$ROOT_DIR" show "${hpref}${LAWS_REL}" > "$headlaws" 2>/dev/null; then
        hr=$(highest_ruling_in "$headlaws")
      else
        hr=""
      fi
      [ -n "$hr" ] || hr=0
      if [ "$n" -le "$hr" ]; then
        echo "$label: ruling $n must be greater than the highest ruling already in the laws ($hr)"
        defects=$((defects + 1)); need_ruling=1
      fi
      staged_laws="$TMPD/stagedlaws"
      if git -C "$ROOT_DIR" show "${ipref}${LAWS_REL}" > "$staged_laws" 2>/dev/null; then
        if ! grep -qE "Ruling ${n}([^0-9]|$)" "$staged_laws"; then
          echo "$label: the laws being committed do not record Ruling $n — an amendment records its ruling in the laws"
          defects=$((defects + 1)); need_ruling=1
        fi
      else
        echo "$label: $LAWS_REL is absent from the tree being committed"
        defects=$((defects + 1)); need_ruling=1
      fi
    fi
  fi

  # 3 — a ticket subject drags its evidence in with it.
  subject=$(head -1 "$msgf" 2>/dev/null)
  tre=$(cfg_scalar ticket_re)
  if [ -n "$tre" ] && [ -n "$subject" ]; then
    tid=$(printf '%s' "$subject" | grep -oE "$tre" | head -1)
    tid="${tid%:}"
    if [ -n "$tid" ]; then
      local nd
      nd=$(cfg_scalar notes_dir); [ -n "$nd" ] || nd="docs/llm-orchestrator/notes"
      if [ "$lbase" = "WORKTREE" ]; then
        mode_landing "$tid" HEAD || defects=$((defects + 1))
      elif [ -z "$(git -C "$ROOT_DIR" ls-tree -d --name-only "${lbase}" -- "$nd" 2>/dev/null)" ]; then
        echo "$label: landing check SKIPPED — $nd is not in the tree at this revision (the hook checked it at commit time)"
      else
        mode_landing "$tid" "$lbase" "${lbase}:" || defects=$((defects + 1))
      fi
    fi
  fi

  # The remedy names the piece that is missing and no other: telling someone to
  # re-run --lock over a lock that is already fresh teaches them the message is
  # boilerplate, and then they stop reading it.
  if [ "$defects" -gt 0 ]; then
    if [ "$need_ruling" = "1" ] && [ "$need_relock" = "1" ]; then
      echo "$label: put \`Ruling <N>\` in the commit message, record it in $LAWS_REL, and re-run --lock under ORCH_CADENCE_UNLOCK=1"
    elif [ "$need_ruling" = "1" ]; then
      echo "$label: put \`Ruling <N>\` in the commit message and record it in $LAWS_REL"
    elif [ "$need_relock" = "1" ]; then
      echo "$label: re-run --lock under ORCH_CADENCE_UNLOCK=1 so the manifest matches what is being committed"
    fi
    return 1
  fi
  return 0
}

mode_commit_msg() { # <msgfile>
  local m
  git_mode ":" "HEAD:"; m=$?
  [ "$m" -eq 1 ] && return 0
  if [ "$m" -eq 2 ]; then
    echo "CADENCE: $CFG_REL does not decode at this revision — refusing (a config nobody can read is not an off switch)"
    return 1
  fi
  [ -f "$1" ] || { echo "CADENCE: no commit message file at $1"; return 1; }
  git_gate ":" "HEAD:" "$1" "CADENCE" "WORKTREE"
}

mode_audit() { # <rev>
  local rev="$1" msgf m
  git -C "$ROOT_DIR" rev-parse --verify -q "${rev}^{commit}" >/dev/null 2>&1 || {
    echo "AUDIT $rev: not a commit"; return 1; }
  git_mode "${rev}:" "${rev}:"; m=$?
  if [ "$m" -eq 1 ]; then
    echo "cadence: off at $rev — --audit needs $CFG_REL with \"enabled\": true at that revision"
    return 1
  fi
  if [ "$m" -eq 2 ]; then
    echo "AUDIT $rev: $CFG_REL does not decode at that revision — refusing"
    return 1
  fi
  msgf="$TMPD/auditmsg"
  git -C "$ROOT_DIR" log -1 --format=%B "$rev" > "$msgf" 2>/dev/null
  git_gate "${rev}:" "${rev}^:" "$msgf" "AUDIT $rev" "$rev"
}

# ---------- argument parsing --------------------------------------------------
MODE=""; ARG1=""; BASE="HEAD"
while [ $# -gt 0 ]; do
  case "$1" in
    --root)     shift; OPT_ROOT="${1:-}" ;;
    --verdict)  MODE="verdict" ;;
    --lock)     MODE="lock" ;;
    --landing)  MODE="landing"; shift; ARG1="${1:-}" ;;
    --commit-msg) MODE="commit-msg"; shift; ARG1="${1:-}" ;;
    --audit)    MODE="audit"; shift; ARG1="${1:-}" ;;
    --base)     shift; BASE="${1:-HEAD}" ;;
    --version)  echo "orch-cadence-check.sh ${ORCH_CADENCE_CHECK_VERSION}"; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

[ -n "$MODE" ] || { usage; exit 1; }
resolve_root

case "$MODE" in
  verdict)    mode_verdict; exit 0 ;;
  lock)       mode_lock; exit $? ;;
  landing)    [ -n "$ARG1" ] || { echo "--landing needs a ticket id"; exit 1; }
              mode_landing "$ARG1" "$BASE"; exit $? ;;
  commit-msg) [ -n "$ARG1" ] || { echo "--commit-msg needs the message file"; exit 1; }
              mode_commit_msg "$ARG1"; exit $? ;;
  audit)      [ -n "$ARG1" ] || { echo "--audit needs a revision"; exit 1; }
              mode_audit "$ARG1"; exit $? ;;
esac
