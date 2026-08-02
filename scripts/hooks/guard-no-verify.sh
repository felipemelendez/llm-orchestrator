#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard.
# Blocks the git-hook bypasses unless the user explicitly opted in:
#   --no-verify, --no-gpg-sign, -c commit.gpgsign=false, an inline `-c alias.`,
#   and `-n` / any combined short cluster containing n on a `git commit`.
# The short form matters: `-n` is git's documented shorthand for --no-verify on
# commit, so for the whole life of this guard every project's pre-commit hook was
# bypassable in two characters while the long form was blocked.
# Reads JSON event from stdin; exits 0 to allow, exits 2 to block.

# NO `set -e` HERE, DELIBERATELY. A blocking guard that aborts mid-script exits
# non-zero-but-not-2, which Claude Code treats as a non-blocking hook error — the
# command then RUNS. Measured: a single invalid-UTF-8 byte in the command made
# BSD sed exit 1 with "RE error: illegal byte sequence", `set -e` aborted before
# the block decision was computed, and a hard reset carrying that byte was
# ALLOWED. Every failure path in a guard has to fall through to the block logic,
# not out of the script. The seds also run under LC_ALL=C so bytes stay bytes.
set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
ALLOW="${ORCH_ALLOW_NO_VERIFY:-0}"

if [[ ",${DISABLED}," == *",orch-guard,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${HOOK_DIR}/../lib/orch-json.sh" ]] && source "${HOOK_DIR}/../lib/orch-json.sh"

# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# Scan the COMMAND, not the whole payload.
#
# This used to grep the raw event JSON, so it blocked any call whose text
# merely contained the flag: `grep -rn -- '--no-verify' scripts/` (a read-only
# search — the single most likely benign hit), `git log --grep='--no-verify'`,
# and even a clean `git commit` whose model-written `description` field said
# "commit without --no-verify". A guard that punishes looking for the thing it
# guards against gets disabled by its users, which costs more than it saves.
#
# orch_scan_source decodes the command, keeps it verbatim when it can re-enter
# a shell, and otherwise treats quoted text as the argument it is. Every
# fallback is toward blocking.
SCAN="${INPUT}"
DECODED=0
if declare -f orch_scan_source >/dev/null 2>&1; then
  SCAN=$(orch_scan_source "${INPUT}")
  # Only the tokenized path licenses the token-level rule below. The fallback
  # paths (undecodable payload, no python3, unbalanced quotes, and crucially a
  # command that RE-ENTERS a shell — `echo '...' | sh`, `awk 'BEGIN{system(...)}'`)
  # all return raw text, where the flag is inside a string the shell will later
  # execute. Testing "did the output differ from the payload" mistook the
  # re-entry fallback for a successful tokenization and let those through.
  orch_scan_is_tokenized "${SCAN}" && DECODED=1
fi
# Same reason as the git guard: a stray non-ASCII byte must not be able to hide
# a flag from a word-boundary match.
SCAN=$(printf '%s' "${SCAN}" | LC_ALL=C tr -c '[:print:][:space:]' ' ')

HIT=0
# An inline alias can carry the flag past every token-level rule, because the
# alias body is a quoted argument that tokenization replaces with a placeholder.
# Scan the RAW command for the FORM; there is no legitimate agent use for it.
RAWCMD="${INPUT}"
declare -f orch_json_field >/dev/null 2>&1 && _RC=$(orch_json_field "${INPUT}" tool_input.command) && [[ -n "${_RC}" ]] && RAWCMD="${_RC}"
if grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:space:]]*alias\.' <<< "${RAWCMD}"; then
  HIT=1
fi
if [[ ${HIT} -eq 0 ]] && [[ ${DECODED} -eq 1 ]] && declare -f orch_shell_segments >/dev/null 2>&1; then
  # Match a git INVOCATION carrying the flag, not the flag's mere presence.
  #
  # After tokenization a quoted single word is indistinguishable from an
  # unquoted one — correctly, since the shell runs them identically. So
  # `grep -rn -- "--no-verify" scripts/` still contains the exact token
  # `--no-verify` and a substring test blocks it. Looking at WHICH command the
  # token is an argument to separates them: a search is not a commit.
  # `git log --grep=--no-verify` also passes, because the token there is
  # `--grep=--no-verify`, not the flag itself.
  while IFS= read -r _seg; do
    [[ -n "${_seg}" ]] || continue
    # `set -f` first: word-splitting is wanted, pathname expansion is not.
    # Measured without it — `git add *` in a directory containing a file named
    # `--no-verify` expanded into the flag and was blocked. A guard's verdict
    # must not depend on what happens to be sitting in the CWD.
    set -f
    set -- ${_seg}
    set +f
    [[ $# -gt 0 ]] || continue
    # A `git` token ANYWHERE in the segment, not just argv[0]. Requiring argv[0]
    # meant one launcher word disarmed the rule: `caffeinate git commit
    # --no-verify`, `arch git commit --no-verify` and `xcrun git ...` all
    # committed with hooks bypassed (proven against a failing pre-commit hook).
    # An allowlist-shaped test inside a deny-shaped guard is the wrong shape.
    _has_git=0
    for _tok in "$@"; do
      case "$(basename "${_tok}")" in git|git.exe) _has_git=1; break ;; esac
    done
    [[ ${_has_git} -eq 1 ]] || continue

    # Is this segment a `git commit`? `-n` is git's documented shorthand for
    # --no-verify on commit ONLY — `git log -n 5` is a count and `git push -n`
    # is a dry run, so the short form is scoped to the commit subcommand.
    _is_commit=0
    for _tok in "$@"; do
      case "${_tok}" in commit) _is_commit=1; break ;; esac
    done

    # Walk the tokens tracking whether the PREVIOUS one takes a value. Without
    # that, `git commit -m -n` (a literal message of "-n") and `git commit -tn`
    # (template named "n") would both be read as the bypass flag.
    _prev_takes_value=0
    for _tok in "$@"; do
      # The explicit forbidden strings are checked FIRST, and unconditionally —
      # `-c` takes a value, and that value IS the bypass in
      # `git -c commit.gpgsign=false commit`. Skipping it as "just an argument"
      # is how adding the value-option table broke a case it was meant to keep.
      case "${_tok}" in
        --no-verify|--no-gpg-sign|commit.gpgsign=false|commit.gpgSign=false) HIT=1; break ;;
      esac
      if [[ ${_prev_takes_value} -eq 1 ]]; then _prev_takes_value=0; continue; fi
      case "${_tok}" in
        -m|-F|-C|-c|-t) _prev_takes_value=1; continue ;;
        --message|--file|--reuse-message|--reedit-message|--template|--fixup|--squash) _prev_takes_value=1; continue ;;
        --*) continue ;;
        -?*)
          [[ ${_is_commit} -eq 1 ]] || continue
          # A combined short cluster: scan left to right and stop at the first
          # char that takes a value — everything after it is that value.
          # `-an` is [a][n] → the bypass. `-tn` is [t] taking "n" → not.
          _rest="${_tok#-}"
          while [[ -n "${_rest}" ]]; do
            _c="${_rest%"${_rest#?}"}"
            case "${_c}" in
              n) HIT=1; break ;;
              m|F|C|c|t) break ;;
            esac
            _rest="${_rest#?}"
          done
          [[ ${HIT} -eq 1 ]] && break
          ;;
      esac
    done
    [[ ${HIT} -eq 1 ]] && break
  done <<< "$(orch_shell_segments "${SCAN}")"
else
  # Undecodable payload → raw substring scan. Noisy, never fail-open.
  grep -qE -- '--no-verify|--no-gpg-sign|-c[[:space:]]+commit\.gpgsign=false' <<< "${SCAN}" && HIT=1
  # `-n` on a commit, in the undecodable case. Deliberately blunt here: this
  # path already accepts false positives in exchange for never failing open.
  grep -qE 'git([^;&|]*[[:space:]])?commit([[:space:]]+[^;&|]*)?[[:space:]]-[A-Za-z]*n([[:space:]]|$)' <<< "${SCAN}" && HIT=1
fi

if [[ ${HIT} -eq 1 ]]; then
  if [[ "${ALLOW}" == "1" ]]; then
    exit 0
  fi
  cat <<MSG >&2
LLM Orchestrator guard: blocked command containing --no-verify or signing bypass.
Set ORCH_ALLOW_NO_VERIFY=1 in your environment to allow.
Profile: ${PROFILE}
MSG
  exit 2
fi

exit 0
