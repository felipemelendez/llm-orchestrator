#!/usr/bin/env bash
# LLM Orchestrator — worktree materialize/rollback engine + active-owner registry.
#
# Makes "no two agents write the same tree" MECHANICAL instead of prose-governed.
# One command creates N isolated git worktrees for a parallel writer batch, claims
# each atomically in an ownership registry, and rolls back EVERYTHING it created if
# any step fails or the process is killed mid-batch. Borrows ECC's ownership-store
# concept in pure shell — no daemon, no DB.
#
# The registry is inlined (single consumer). A claim is an atomic `mkdir`; the
# meta file is written via tempfile+`mv` so a concurrent reader never sees a
# half-written claim. The irreducible mkdir→meta window (a kill in between leaves
# a meta-less dir) is reclaimed by AGE-GATED prune: a meta-less claim older than
# ORCH_REGISTRY_STALE_SECS is an abandoned orphan and is removed; a recent one is
# a live in-progress claim and is left alone. The same age gate stops prune from
# racing a just-created claim whose worktree add has not finished yet.
#
# The writer's runtime anti-clobber guard is a separate atomic `mkdir
# <wt>/.orch-active` mutex in orch-implementer — this script governs CREATE-time
# ownership; that mutex governs WRITE-time exclusion.
#
# Usage:
#   orch-worktree-materialize.sh [--base <ref>] <session_id> <slug> [slug ...]
#   orch-worktree-materialize.sh --dry-run [--base <ref>] <session_id> <slug> [...]
#   orch-worktree-materialize.sh --release <session_id> <slug>
#   orch-worktree-materialize.sh --prune
#   orch-worktree-materialize.sh --list
#
# Bash 3.2 compatible. Destructive git inside this trusted script is intentional
# and out of the PreToolUse guard's scope (the guard inspects the agent's direct
# command, not a script's internals).

# NOTE: sourcing this file (the white-box tests do) sets -uo pipefail in the
# caller's shell — intentional for this script's own safety.
set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib/orch-project.sh
. "${_SCRIPT_DIR}/lib/orch-project.sh"

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
# Claims younger than this (seconds) are treated as live/in-progress and never
# pruned. Default 120s — a worktree add completes in well under that. Tests set 0.
STALE_SECS="${ORCH_REGISTRY_STALE_SECS:-120}"

init_paths() {
  local hash
  hash="$(orch_project_hash)"
  SESSION_DIR="${HOME_DIR}/sessions/${hash}"
  OWNERS="${SESSION_DIR}/owners"
  mkdir -p "${OWNERS}"
}

sanitize() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# epoch mtime of a path (BSD stat, then GNU stat). If stat is unavailable, return
# a far-future sentinel so age comes out negative and prune conservatively SKIPS
# (never mass-reclaims) rather than treating everything as stale.
_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 9999999999; }

# --- registry --------------------------------------------------------------

# print the owner session_id of a slug, or nothing if unclaimed / mid-claim.
registry_owner() {
  local meta="${OWNERS}/$1/meta"
  [[ -s "${meta}" ]] || return 0   # absent or zero-length → in-progress / none
  cut -f1 "${meta}"
}

# claim <slug> <branch> <wt_abspath> <session_id>. atomic; 1 if already owned.
registry_claim() {
  local slug="$1" branch="$2" wt="$3" sid="$4"
  if ! mkdir "${OWNERS}/${slug}" 2>/dev/null; then
    printf 'orch-materialize: slug "%s" already claimed by %s\n' "${slug}" "$(registry_owner "${slug}")" >&2
    return 1
  fi
  local tmp="${OWNERS}/${slug}/.meta.$$.${RANDOM}"
  # On a write failure (e.g. disk full), remove the claim dir we just won so the
  # slug is freed immediately instead of waiting out the prune TTL.
  printf '%s\t%s\t%s\t%s\n' "${sid}" "${branch}" "${wt}" "$(date +%s 2>/dev/null || echo 0)" > "${tmp}" || { rm -rf "${OWNERS}/${slug}" 2>/dev/null; return 1; }
  mv -f "${tmp}" "${OWNERS}/${slug}/meta" || { rm -rf "${OWNERS}/${slug}" 2>/dev/null; return 1; }
}

# release <slug> <session_id>. idempotent if already gone (any caller). refuses a
# non-owner, and refuses an in-progress (empty-meta) claim rather than delete it.
registry_release() {
  local slug="$1" sid="$2" dir="${OWNERS}/$1"
  [[ -d "${dir}" ]] || return 0
  [[ -s "${dir}/meta" ]] || { printf 'orch-materialize: refusing to release in-progress claim "%s"\n' "${slug}" >&2; return 1; }
  local owner; owner="$(registry_owner "${slug}")"
  if [[ "${owner}" != "${sid}" ]]; then
    printf 'orch-materialize: release denied — "%s" owned by %s, not %s\n' "${slug}" "${owner}" "${sid}" >&2
    return 1
  fi
  rm -rf "${dir}"
}

# Drop stale claims. AGE-GATED: only claims older than STALE_SECS are eligible,
# so a live in-progress claim (meta-less, recent) and a just-created claim whose
# worktree add is still running (meta-ful, worktree not yet on disk, recent) are
# both left alone. Among old-enough claims: remove a meta-less one (abandoned
# in-progress orphan) or a meta-ful one whose recorded worktree is gone.
registry_prune() {
  [[ -d "${OWNERS}" ]] || return 0
  local d meta wt now age
  now="$(date +%s 2>/dev/null || echo 0)"
  for d in "${OWNERS}"/*/; do
    [[ -d "${d}" ]] || continue
    d="${d%/}"
    age=$(( now - $(_mtime "${d}") ))
    [[ ${age} -ge ${STALE_SECS} ]] || continue   # too young — leave it
    meta="${d}/meta"
    if [[ -s "${meta}" ]]; then
      wt="$(cut -f3 "${meta}")"
      [[ -d "${wt}" ]] || rm -rf "${d}" 2>/dev/null || true
    else
      rm -rf "${d}" 2>/dev/null || true           # old + meta-less → orphan
    fi
  done
}

do_list() {
  [[ -d "${OWNERS}" ]] || return 0
  local d meta content
  for d in "${OWNERS}"/*/; do
    [[ -d "${d}" ]] || continue
    meta="${d%/}/meta"
    # Read once into a variable so a concurrent release (rm -rf) between a test
    # and the read cannot fail the read mid-list. Empty/absent → skip. (cat, not
    # $(<file), because the $(<file) fast-read form cannot carry a 2>/dev/null.)
    content="$(cat "${meta}" 2>/dev/null)"
    [[ -n "${content}" ]] || continue
    printf '%s\t%s\n' "$(basename "${d%/}")" "${content}"
  done
}

# --- materialize -----------------------------------------------------------

# rollback list (parallel indexed arrays — bash 3.2 has no associative arrays).
# Re-initialized at the top of do_materialize so a sourced second run is clean.
R_SLUG=(); R_PATH=(); R_BRANCH=()

rollback_all() {
  local i
  for (( i=${#R_SLUG[@]}-1; i>=0; i-- )); do
    # We created these claims this run, so remove the claim dir directly with
    # rm -rf — INTENTIONALLY bypassing registry_release's ownership/in-progress
    # guards, which exist for external callers, not for our own teardown. Claim
    # first (frees the slug before the tree disappears, closing the prune/
    # re-claim window), then the worktree, then the branch.
    rm -rf "${OWNERS}/${R_SLUG[$i]}" >/dev/null 2>&1 || true
    git worktree remove --force "${R_PATH[$i]}" >/dev/null 2>&1 || true
    git branch -D "${R_BRANCH[$i]}" >/dev/null 2>&1 || true
  done
}

do_materialize() {
  R_SLUG=(); R_PATH=(); R_BRANCH=()
  local base="HEAD" dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) break ;;
    esac
  done
  local sid="${1:-}"; shift || true
  [[ -n "${sid}" ]] || { echo "orch-materialize: empty session id — is the plugin's SessionStart hook installed? (try --sid)" >&2; exit 2; }
  [[ "${sid}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "orch-materialize: invalid session id (allowed: A-Za-z0-9._-) — got '${sid}'" >&2; exit 2; }
  [[ $# -gt 0 ]] || { echo "usage: orch-worktree-materialize.sh [--base ref] [--dry-run] <session_id> <slug> [slug ...]" >&2; exit 2; }

  # Must run from the repo root — the engine builds worktree paths relative to it.
  # `--show-prefix` is empty exactly at the root and is symlink-immune (unlike a
  # show-toplevel == PWD compare, which breaks on macOS /var → /private/var).
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "orch-materialize: not inside a git repository" >&2; exit 2; }
  [[ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]] || { echo "orch-materialize: must be run from the repo root (cd \"\$(git rev-parse --show-toplevel)\")" >&2; exit 2; }

  registry_prune   # once per batch (not per claim) — clear stale claims up front.

  # distinctness on the SANITIZED slugs (so 'a b' and 'a_b', which both sanitize
  # to 'a_b', are caught here cleanly rather than at the claim mkdir).
  local raw slug rel abs branch dup
  dup="$(for raw in "$@"; do sanitize "${raw}"; done | sort | uniq -d)"
  [[ -z "${dup}" ]] || { printf 'orch-materialize: duplicate slug(s) after sanitization: %s\n' "${dup}" >&2; exit 1; }

  # pre-flight (optimization only; the claim mkdir is the authoritative guard).
  for raw in "$@"; do
    slug="$(sanitize "${raw}")"; rel=".worktrees/${slug}"; branch="orch/${sid}/${slug}"
    [[ -e "${rel}" ]] && { echo "orch-materialize: path exists: ${rel}" >&2; exit 1; }
    git show-ref --verify --quiet "refs/heads/${branch}" && { echo "orch-materialize: branch exists: ${branch}" >&2; exit 1; }
    [[ -d "${OWNERS}/${slug}" ]] && { echo "orch-materialize: slug claimed: ${slug}" >&2; exit 1; }
  done

  if [[ ${dry} -eq 1 ]]; then
    for raw in "$@"; do
      slug="$(sanitize "${raw}")"
      printf 'DRY %s\t%s/.worktrees/%s\torch/%s/%s\n' "${slug}" "${PWD}" "${slug}" "${sid}" "${slug}"
    done
    return 0
  fi

  # Self-clearing trap: the handler disarms itself before rolling back, so the
  # `exit 1` inside it does not re-enter the EXIT trap and roll back twice.
  trap 'trap - EXIT INT TERM HUP; rollback_all; exit 1' EXIT INT TERM HUP
  for raw in "$@"; do
    slug="$(sanitize "${raw}")"; abs="${PWD}/.worktrees/${slug}"; branch="orch/${sid}/${slug}"
    registry_claim "${slug}" "${branch}" "${abs}" "${sid}" || exit 1
    # record BEFORE the worktree add so a failed add still rolls back the claim.
    R_SLUG+=("${slug}"); R_PATH+=("${abs}"); R_BRANCH+=("${branch}")
    git worktree add -b "${branch}" "${abs}" "${base}" >/dev/null 2>&1 || { echo "orch-materialize: git worktree add failed: ${slug}" >&2; exit 1; }
    # exclude .orch-* BEFORE dropping the files (so a mid-step kill leaves nothing
    # untracked). rev-parse resolves info/exclude correctly even in a linked
    # worktree, where .git is a file, not a directory.
    local excl; excl="$(git -C "${abs}" rev-parse --git-path info/exclude 2>/dev/null || true)"
    [[ -n "${excl}" ]] && { grep -qx '\.orch-\*' "${excl}" 2>/dev/null || printf '.orch-*\n' >> "${excl}"; }
    printf '%s\n' "${sid}" > "${abs}/.orch-worktree-lock" || { echo "orch-materialize: provenance write failed: ${slug}" >&2; exit 1; }
    : > "${abs}/.orch-worktree" || { echo "orch-materialize: provenance write failed: ${slug}" >&2; exit 1; }
  done
  # Batch is committed. Clear the trap BEFORE emitting output so a broken-pipe
  # (EPIPE) on a closed consumer cannot roll back successfully-created worktrees;
  # `|| true` + explicit success keep the exit code clean.
  trap - EXIT INT TERM HUP
  local i
  for (( i=0; i<${#R_SLUG[@]}; i++ )); do
    printf '%s\t%s\t%s\n' "${R_SLUG[$i]}" "${R_PATH[$i]}" "${R_BRANCH[$i]}" || true
  done
  return 0
}

# --- dispatch --------------------------------------------------------------

main() {
  case "${1:-}" in
    --release)
      init_paths
      [[ $# -eq 3 ]] || { echo "usage: --release <session_id> <slug>" >&2; exit 2; }
      registry_release "$(sanitize "$3")" "$2"
      ;;
    --prune) init_paths; registry_prune ;;
    --list)  init_paths; do_list ;;
    --sid)   init_paths; [[ -s "${SESSION_DIR}/sid" ]] && printf '%s\n' "$(<"${SESSION_DIR}/sid")" || true ;;
    -h|--help|"") echo "usage: orch-worktree-materialize.sh [--base ref] [--dry-run] <session_id> <slug> [slug ...] | --release <sid> <slug> | --prune | --list | --sid" ;;
    *) init_paths; do_materialize "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
