#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard (matcher: Edit|Write|MultiEdit) —
# protects the tools the verification layer depends on.
#
# WHY THIS EXISTS. The evidence ledger records the exit code of a lint,
# typecheck or test run and the verify gate reads it. Nothing stopped the agent
# editing `eslint.config.js`, `biome.json` or `.ruff.toml` first. The ledger
# then faithfully records a green run of a check that was just loosened — not a
# fabrication, so no gate fires. The evidence is true and worthless, which is a
# worse failure than a lie because every mechanism downstream believes it.
#
# Weakening the check to make the check pass is one of the most common agent
# shortcuts. This blocks it at the only moment it is observable.
#
# CREATING a config is allowed; only editing an EXISTING one is blocked. A
# project adopting a linter is doing the opposite of evading one.
#
# Override with ORCH_ALLOW_CONFIG_EDIT=1 in the hook's own environment (a
# deliberate human act — an inline prefix in the scanned command does not
# reach this process). Gated by ORCH_HOOK_PROFILE (off under minimal) and
# ORCH_DISABLED_HOOKS=orch-config-protection.
#
# NO `set -e` — see guard-no-verify.sh. A guard that aborts exits non-zero-but-
# not-2, which the harness reads as a hook error and the tool call proceeds.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ "${ORCH_ALLOW_CONFIG_EDIT:-0}" == "1" ]]; then exit 0; fi
if [[ ",${DISABLED}," == *",orch-config-protection,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${HOOK_DIR}/../lib/orch-json.sh" ]] && source "${HOOK_DIR}/../lib/orch-json.sh"

INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

# Linter, formatter and typecheck strictness. NOT pyproject.toml, Cargo.toml,
# package.json or go.mod — those carry dependency and build metadata that
# ordinary work legitimately edits, and blocking them would make the guard
# something people turn off.
#
# ONE list, pattern-shaped, used by BOTH the Edit path and the Bash path.
# The old exact-name enumeration had sibling gaps an audit walked straight
# through: eslint.config.mts, .prettierrc.toml, .stylelintrc.yml,
# .markdownlint.jsonc, .golangci.toml and tsconfig.build.json were all
# editable while their siblings were blocked. Tools grow config dialects
# faster than a name list grows arms; match the family, not the spelling.
orch_is_protected_cfg() { # <lowercased basename> → 0 when protected
  case "$1" in
    .eslintrc|.eslintrc.*|eslint.config.*|.eslintignore) return 0 ;;
    .prettierrc|.prettierrc.*|prettier.config.*|.prettierignore) return 0 ;;
    biome.json|biome.jsonc|biome.config.*) return 0 ;;
    .ruff.toml|ruff.toml) return 0 ;;
    .flake8|setup.cfg|mypy.ini|.mypy.ini|pyrightconfig.json) return 0 ;;
    tsconfig.json|tsconfig.*.json|jsconfig.json) return 0 ;;
    .stylelintrc|.stylelintrc.*|stylelint.config.*|.stylelintignore) return 0 ;;
    .markdownlint.*|.markdownlintrc|.markdownlintignore) return 0 ;;
    .rubocop.yml|.golangci.*|clippy.toml|.clippy.toml) return 0 ;;
    .editorconfig|.pre-commit-config.*) return 0 ;;
    *) return 1 ;;
  esac
}

TARGET=""
declare -f orch_json_field >/dev/null 2>&1 && TARGET=$(orch_json_field "${INPUT}" tool_input.file_path)

# --- Bash path -----------------------------------------------------------------
# This hook also runs on the Bash matcher: `sed -i 's/error/off/'
# eslint.config.js` loosens a checker exactly as an Edit does, and binding the
# guard to Edit|Write|MultiEdit only meant the shell was a free side door.
# Scoped to WRITERS: in-place editors and redirection targets. Reading a
# config (cat/grep) stays free — a guard that blocks looking at the thing it
# protects gets switched off.
if [[ -z "${TARGET}" ]] && declare -f orch_json_field >/dev/null 2>&1; then
  _CMD=$(orch_json_field "${INPUT}" tool_input.command)
  if [[ -n "${_CMD}" ]]; then
    _FLAT=$(printf '%s' "${_CMD}" | LC_ALL=C tr -c '[:print:]' ' ')
    # (a) redirection targets: `> eslint.config.js`, `2>>`, `| tee <file>`.
    _TGTS=$(printf '%s' "${_FLAT}" \
      | command grep -oE '([0-9]?>>?|tee([[:space:]]+-a)?)[[:space:]]*[^[:space:];|&<>]+' \
      | LC_ALL=C sed -E -e 's/^[0-9]?>>?[[:space:]]*//' -e 's/^tee([[:space:]]+-a)?[[:space:]]*//' || true)
    # (b) in-place writers: every argument word is a candidate target.
    if printf '%s' "${_FLAT}" | command grep -qE '(^|[;&|([:space:]])((sed|perl|ruby)[[:space:]][^;&|]*[[:space:]]-i|(sed|perl|ruby)[[:space:]]+-i|(sponge|truncate|mv|cp|install|ln|patch|ex|ed)([[:space:]]|$))'; then
      _TGTS="${_TGTS}
$(printf '%s' "${_FLAT}" | tr ' ' '\n')"
    fi
    while IFS= read -r _t; do
      [[ -n "${_t}" ]] || continue
      _t=$(printf '%s' "${_t}" | LC_ALL=C sed -e "s/[\"']//g")
      [[ -n "${_t}" ]] || continue
      _b=$(basename "${_t}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
      [[ -n "${_b}" ]] || continue
      if orch_is_protected_cfg "${_b}" && [[ -e "${_t}" || -L "${_t}" ]]; then
        TARGET="${_t}"
        break
      fi
    done <<< "${_TGTS}"
    [[ -n "${TARGET}" ]] || exit 0
  fi
fi

if [[ -z "${TARGET}" ]]; then
  # Could not decode a path. A truncated or unexpected payload must not be a
  # free pass, but neither should it block every edit in the session — so fall
  # back to a grep for a protected name anywhere in the payload.
  declare -f orch_json_field >/dev/null 2>&1 || exit 0
  TARGET=$(printf '%s' "${INPUT}" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  [[ -n "${TARGET}" ]] || exit 0
fi

# Basename, lowercased: on APFS and NTFS `.ESLINTRC.JS` is the same file.
BASE=$(basename "${TARGET}" | tr '[:upper:]' '[:lower:]')

orch_is_protected_cfg "${BASE}" || exit 0

# Only an EXISTING file is protected. Adopting a linter is the opposite of
# evading one. Absent means absent — any other stat failure (a permission
# problem, a path we cannot resolve) is treated as present, so the uncertain
# case blocks rather than passes.
if [[ ! -e "${TARGET}" && ! -L "${TARGET}" ]]; then
  if [[ -d "$(dirname "${TARGET}")" ]]; then
    exit 0   # parent readable, file genuinely absent → creation
  fi
fi

cat <<MSG >&2
LLM Orchestrator guard: blocked an edit to an existing checker config.
  ${TARGET}

The verification layer reads exit codes from this tool. Editing its config to
make a check pass produces a green run that is technically true and tells you
nothing — and every gate downstream believes it.

If the check is wrong, fix the code, or narrow the rule for one file with an
inline disable comment and say why. If the config genuinely needs to change as
part of this work, that is a decision for the human: set
ORCH_ALLOW_CONFIG_EDIT=1 in your environment.
Profile: ${PROFILE}
MSG
exit 2
