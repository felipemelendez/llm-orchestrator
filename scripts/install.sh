#!/usr/bin/env bash
# LLM Orchestrator installer / verifier.
# Usage:
#   ./scripts/install.sh --check         verify the local checkout is sane
#   ./scripts/install.sh --link          symlink into ~/.claude/llm-orchestrator
#   ./scripts/install.sh --copy <dir>    copy skills/commands/templates into <dir>/.claude/
#   ./scripts/install.sh --global        render the cadence block into ~/.claude/CLAUDE.md
#   ./scripts/install.sh --codex         the same block into ~/.codex/AGENTS.md (the Codex plugin brings the skill and hooks)
#
# --global and --codex are the only modes that write outside a project, and both
# write only under $HOME — which they take from the environment, so a test can
# point them at a temporary directory and prove it.
#
# Scope note: --check validates the SOURCE CHECKOUT it lives in — never an
# installed tree (install.sh is not among the files --copy writes, so it cannot
# be pointed at one). A --copy install is verified at install time instead:
# --copy fails, rather than printing success, if the hook-path rewrite did not
# produce absolute paths that exist on disk.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# The cadence block. ONE source of truth — templates/cadence-global-block.md —
# rendered between two markers into the global instructions file of whichever
# harness is being set up. Codex spends a single 32 KiB documentation budget
# global-first and then root-down, so an oversized global block starves the
# project's own AGENTS.md; the block is capped at 2 KiB and a test holds it
# there.
# ---------------------------------------------------------------------------
BLOCK_START='<!-- ORCH:LAWS:START -->'
BLOCK_END='<!-- ORCH:LAWS:END -->'
BLOCK_SRC="${ROOT}/templates/cadence-global-block.md"

# render_block <target-file>
#   absent               -> created with the block
#   present, no markers  -> appended after one blank line, the file untouched above
#   present, one pair    -> the region between the markers replaced in place
#   more than one pair   -> refused in one line, nothing written
# The write goes through a temp file and a mv, so an interrupted run can never
# leave half a global instructions file behind.

# The link chain, walked in bash 3.2 with no GNU flag. A dotfiles-managed
# ~/.claude/CLAUDE.md is a LINK, and writing through `mv` onto the link
# replaces the link with a regular file: the dotfiles copy never gets the
# block and the person's own management of the file is silently undone.
# HOME as the environment spells it, and where it really is: both count as
# "under HOME", because macOS spells its temp directories through a link.
home_real() { (cd "${HOME}" 2>/dev/null && pwd -P) || printf '%s' "${HOME}"; }
under_home() {  # under_home <canonical path> -> 0 when it lies under HOME
  case "$1" in "${HOME}"/*) return 0 ;; esac
  case "$1" in "$(home_real)"/*) return 0 ;; esac
  return 1
}

resolve_target() {
  local p="$1" n=0 link parent
  while [[ -L "${p}" && ${n} -lt 8 ]]; do
    link=$(readlink "${p}" 2>/dev/null) || break
    [[ -n "${link}" ]] || break
    case "${link}" in
      /*) p="${link}" ;;
      *)  parent="${p%/*}"; [[ -n "${parent}" ]] || parent="/"; p="${parent}/${link}" ;;
    esac
    n=$((n+1))
  done
  # Canonical: a target spelled through `..` or a linked parent is judged by
  # where it really is, not by how it was written.
  local dir base
  dir="${p%/*}"; base="${p##*/}"
  [[ -n "${dir}" ]] || dir="/"
  if [[ -d "${dir}" ]]; then
    dir="$(cd "${dir}" 2>/dev/null && pwd -P)" || dir="${p%/*}"
    p="${dir%/}/${base}"
  fi
  printf '%s' "${p}"
}

# The first free backup name. A `.bak` written on every run holds the state of
# the LAST run, not the state before this installer ever touched the file.
backup_name() {
  local b="$1.bak" n=1
  while [[ -e "${b}" || -L "${b}" ]]; do b="$1.bak.${n}"; n=$((n+1)); done
  printf '%s' "${b}"
}

# Is the region between the markers a block this plugin rendered? The installer
# cannot parse markdown, and it must not: a marker pair the person wrote inside
# a fenced EXAMPLE is not its region, and replacing it deletes their text. The
# test is content: equal to the current block, or carrying the block's own
# heading and the law it has always carried.
_block_interior() { sed '1d;$d' "$1"; }
_region_genuine() { # <region interior on stdin as a file>
  local first
  first=$(grep -m1 -v '^[[:space:]]*$' "$1" || true)
  [[ "${first}" == "## The cadence" ]] || return 1
  grep -q 'docs/llm-orchestrator/LAWS.md' "$1" || return 1
  return 0
}

render_block() {
  local target="$1" tmp starts ends sline eline resolved bak
  if [[ ! -f "${BLOCK_SRC}" ]]; then
    echo "refused: templates/cadence-global-block.md is missing — nothing was written" >&2
    return 1
  fi
  if ! grep -qF "${BLOCK_START}" "${BLOCK_SRC}" || ! grep -qF "${BLOCK_END}" "${BLOCK_SRC}"; then
    echo "refused: templates/cadence-global-block.md has lost its markers — nothing was written" >&2
    return 1
  fi
  [[ "${RENDER_CHECK_ONLY:-0}" == "1" ]] || mkdir -p "$(dirname "${target}")"
  if [[ -L "${target}" && ! -e "${target}" ]]; then
    echo "refused: ${target} is a link that resolves to nothing ($(readlink "${target}")) — fix the link; nothing was written" >&2
    return 1
  fi
  resolved="$(resolve_target "${target}")"
  if [[ "${resolved}" != "${target}" ]]; then
    if ! under_home "${resolved}"; then
      echo "refused: ${target} is a link to ${resolved}, which is outside ${HOME} — this installer writes only under HOME; nothing was written" >&2
      return 1
    fi
    [[ "${RENDER_CHECK_ONLY:-0}" == "1" ]] || mkdir -p "$(dirname "${resolved}")"
  fi
  target="${resolved}"
  if [[ -e "${target}" && ! -f "${target}" ]]; then
    echo "refused: ${target} exists and is not a regular file — nothing was written" >&2
    return 1
  fi
  local tdir="${target%/*}"; [[ -n "${tdir}" ]] || tdir="/"
  if [[ -d "${tdir}" && ! ( -w "${tdir}" && -x "${tdir}" ) ]] || [[ -f "${target}" && ! -w "${target}" ]]; then
    echo "refused: ${target} (or its directory) is not writable by this user — nothing was written" >&2
    return 1
  fi
  starts=0; ends=0
  if [[ -f "${target}" ]]; then
    starts=$(grep -cF "${BLOCK_START}" "${target}" || true)
    ends=$(grep -cF "${BLOCK_END}" "${target}" || true)
  fi
  if [[ "${starts}" != "${ends}" || "${starts}" -gt 1 ]]; then
    echo "refused: ${target} carries ${starts} start and ${ends} cadence markers — fix it by hand; nothing was changed" >&2
    return 1
  fi
  if [[ "${starts}" -eq 1 ]]; then
    sline=$(grep -nF "${BLOCK_START}" "${target}" | head -1 | cut -d: -f1)
    eline=$(grep -nF "${BLOCK_END}" "${target}" | head -1 | cut -d: -f1)
    if [[ "${sline}" -ge "${eline}" ]]; then
      echo "refused: ${target} has its cadence markers out of order — fix it by hand; nothing was changed" >&2
      return 1
    fi
    # Provenance before replacement.
    local reg cur rc=0
    reg="$(mktemp "${tdir}/.orch-region.XXXXXX")" || return 1
    cur="$(mktemp "${tdir}/.orch-cur.XXXXXX")" || return 1
    if [[ $((eline - sline)) -gt 1 ]]; then
      sed -n "$((sline + 1)),$((eline - 1))p" "${target}" > "${reg}"
    else
      : > "${reg}"
    fi
    _block_interior "${BLOCK_SRC}" > "${cur}"
    if cmp -s "${reg}" "${cur}"; then
      rm -f "${reg}" "${cur}"
      [[ "${RENDER_CHECK_ONLY:-0}" == "1" ]] || echo "rendered ${target} (unchanged)"
      return 0
    fi
    if ! _region_genuine "${reg}"; then
      rm -f "${reg}" "${cur}"
      echo "refused: ${target} lines ${sline}-${eline} carry the cadence markers around text this installer did not write — it will not replace text it cannot prove is its own. Move the sample out of ${target}, or delete those two marker lines, then re-run. Nothing was written." >&2
      return 1
    fi
    rm -f "${reg}" "${cur}"
    [[ "${RENDER_CHECK_ONLY:-0}" == "1" ]] && return 0
    bak="$(backup_name "${target}")"
    cp "${target}" "${bak}"
  fi
  # RENDER_CHECK_ONLY=1 runs every refusal above and writes nothing: --codex
  # asks that question in its preflight, before its first write.
  [[ "${RENDER_CHECK_ONLY:-0}" == "1" ]] && return 0
  # mktemp creates the file itself, exclusively: a link someone planted under
  # a guessable name is never written through.
  tmp="$(mktemp "${tdir}/.orch-render.XXXXXX")" || return 1
  if [[ "${starts}" -eq 1 ]]; then
    awk -v s="${BLOCK_START}" -v e="${BLOCK_END}" -v b="${BLOCK_SRC}" '
      index($0, s) && !done { while ((getline l < b) > 0) print l; close(b); skip = 1; done = 1 }
      skip { if (index($0, e)) skip = 0; next }
      { print }
    ' "${target}" > "${tmp}"
  elif [[ -f "${target}" ]]; then
    { awk '{ last = $0; print } END { if (NR > 0 && last != "") print "" }' "${target}"
      cat "${BLOCK_SRC}"; } > "${tmp}"
  else
    cat "${BLOCK_SRC}" > "${tmp}"
  fi
  mv "${tmp}" "${target}"
  if [[ -n "${bak:-}" ]]; then
    echo "rendered ${target} (replaced lines ${sline}-${eline}; backup ${bak})"
  else
    echo "rendered ${target} ($(wc -c < "${BLOCK_SRC}" | tr -d ' ') bytes)"
  fi
  [[ "${target}" != "$1" ]] && echo "  (through the link $1)"
  return 0
}

# The layers report — READ ONLY, and it honours HOME from the environment. A
# few yes/no lines, because "is the cadence actually on here?" is otherwise
# several separate things to remember.
_has_block() { [[ -f "$1" ]] && grep -qF "${BLOCK_START}" "$1" 2>/dev/null && echo yes || echo no; }
# `codex plugin add` records the plugin in config.toml; `enabled = false` in
# that table means it is installed but off. Read only.
codex_plugin_on() {
  [[ -f "${HOME:-}/.codex/config.toml" ]] || return 1
  awk '
    /^[[:space:]]*\[/ { inside = ($0 ~ /^[[:space:]]*\[plugins\."llm-orchestrator@llm-orchestrator"\][[:space:]]*$/); if (inside) found = 1; next }
    inside && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false/ { off = 1 }
    END { exit (found && !off) ? 0 : 1 }
  ' "${HOME}/.codex/config.toml"
}
# What an earlier --codex left that the plugin now provides: hook entries in
# ~/.codex/hooks.json and the marked skill copy. Both make Codex list a check twice.
_codex_leftovers() {
  local h="${HOME:-}" n="" found=()
  if [[ -f "${h}/.codex/hooks.json" ]] && command -v python3 >/dev/null 2>&1; then
    n=$(python3 "${ROOT}/scripts/lib/codex-old-hooks.py" count "${h}/.codex/hooks.json" "${ROOT}" 2>/dev/null || true)
  fi
  [[ -n "${n}" && "${n}" != "0" ]] && found+=("${n} hook entries in ${h}/.codex/hooks.json")
  [[ -f "${h}/.agents/skills/cadence/.orch-installed" ]] && found+=("the skill copy in ${h}/.agents/skills/cadence")
  if [[ ${#found[@]} -eq 0 ]]; then echo none; else printf '%s' "${found[0]}"; [[ ${#found[@]} -gt 1 ]] && printf ', %s' "${found[1]}"; printf ' (re-run --codex)\n'; fi
}
layers_report() {
  local h="${HOME:-}" proj="${CLAUDE_PROJECT_DIR:-${PWD}}"
  echo "layers present on this machine:"
  printf '  %-44s %s\n' "${h}/.claude/CLAUDE.md cadence block:" "$(_has_block "${h}/.claude/CLAUDE.md")"
  printf '  %-44s %s\n' "${h}/.codex/AGENTS.md cadence block:" "$(_has_block "${h}/.codex/AGENTS.md")"
  printf '  %-44s %s\n' "Codex plugin llm-orchestrator@llm-orchestrator:" \
    "$(codex_plugin_on && echo yes || echo no)"
  printf '  %-44s %s\n' "left by an earlier --codex:" "$(_codex_leftovers)"
  printf '  %-44s %s\n' "${proj}/docs/llm-orchestrator/cadence.json:" \
    "$([[ -f "${proj}/docs/llm-orchestrator/cadence.json" ]] && echo yes || echo no)"
}

cmd="${1:-}"
case "${cmd}" in
  --check)
    fail=0
    degraded=""
    for f in README.md AGENTS.md CLAUDE.md concise-agent-protocol.md ARCHITECTURE.md \
             .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json \
             .codex-plugin/plugin.json; do
      if [[ ! -f "${ROOT}/${f}" ]]; then
        echo "missing: ${f}"; fail=1
      fi
    done
    for d in skills commands agents templates hooks scripts/hooks scripts/lib output-styles docs examples tests; do
      if [[ ! -d "${ROOT}/${d}" ]]; then
        echo "missing dir: ${d}"; fail=1
      fi
    done

    # Non-hook infrastructure. Hook SCRIPTS are deliberately absent from this
    # list: they are derived from hooks/hooks.json below, because the previous
    # hand-maintained copy of that list drifted two entries behind reality and
    # --check kept saying OK with shipped hooks deleted.
    for f in scripts/lib/orch-lock.sh scripts/lib/orch-protocol.sh scripts/lib/orch-handoff.sh \
             scripts/lib/orch-project.sh scripts/lib/orch-signals.sh \
             scripts/lib/orch-json.sh scripts/lib/orch-arch.sh scripts/lib/orch-regression.sh \
             scripts/lib/orch-detect.sh scripts/lib/check-hook-paths.py \
             scripts/lib/orch-git-classify.py \
             scripts/orch-worktree-materialize.sh scripts/orch-worktree-integrate.sh \
             scripts/statusline.sh scripts/protocol-lint.sh output-styles/orchestrator.md \
             docs/install.md templates/settings.json scripts/lib/orch-review.py \
             skills/requesting-code-review/references/seat-schema.json \
             skills/requesting-code-review/references/refuter-schema.json \
             skills/brainstorming/scripts/server.cjs skills/using-orchestrator/SKILL.md \
             skills/cadence/SKILL.md skills/cadence/CADENCE.md \
             skills/cadence/scripts/orch-cadence-gate.sh skills/cadence/scripts/orch-cadence-check.sh \
             skills/cadence/scripts/cadence-detect.sh skills/cadence/scripts/cadence-init.sh \
             skills/cadence/references/commit-msg skills/cadence/references/laws.md \
             templates/cadence-global-block.md scripts/lib/orch-task-resources.py \
             skills/cadence/scripts/orch-task-resources.py \
             scripts/hooks/codex-cadence-adapter.sh scripts/hooks/codex-verify-gate.sh \
             scripts/lib/codex-cadence-read-command.py scripts/lib/codex-completion-check.py \
             scripts/lib/codex-old-hooks.py \
             docs/codex.md docs/codex-provider.md; do
      if [[ ! -f "${ROOT}/${f}" ]]; then
        echo "missing: ${f}"; fail=1
      fi
    done

    # Commands and agents ship without a wiring manifest, so this list is the
    # manifest. It fails closed on deletion (the reproduced blind spot); a new
    # command/agent must be appended here to be guarded.
    for f in agents/orch-debugger.md agents/orch-explorer.md \
             agents/orch-implementer.md agents/orch-researcher.md \
             agents/orch-spec-reviewer.md \
             commands/cadence-init.md \
             commands/debug.md commands/dispatch.md commands/finish.md commands/forget.md \
             commands/handoff.md commands/init.md commands/onboard.md commands/plan.md \
             commands/remember.md commands/research.md commands/review.md commands/skills.md \
             commands/verify.md commands/worktree.md; do
      if [[ ! -f "${ROOT}/${f}" ]]; then
        echo "missing: ${f}"; fail=1
      fi
    done

    # Every template that commands/skills/agents name must exist.
    while IFS= read -r ref; do
      [[ -z "${ref}" ]] && continue
      if [[ ! -f "${ROOT}/${ref}" ]]; then
        echo "missing referenced file: ${ref}"; fail=1
      fi
    done < <(grep -rhoE 'templates/[a-zA-Z0-9_-]+\.(md|json)' \
               "${ROOT}/commands" "${ROOT}/skills" "${ROOT}/agents" 2>/dev/null | sort -u)

    # Every /llm-orchestrator:<name> the docs advertise must resolve to a
    # command or a skill.
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      if [[ ! -f "${ROOT}/commands/${name}.md" && ! -f "${ROOT}/skills/${name}/SKILL.md" ]]; then
        echo "documented but missing: /llm-orchestrator:${name}"; fail=1
      fi
    done < <(grep -ohE '/llm-orchestrator:[a-z-]+' \
               "${ROOT}/CLAUDE.md" "${ROOT}/README.md" "${ROOT}/docs/install.md" 2>/dev/null \
             | sed 's|.*:||' | sort -u)

    # Every skill must have SKILL.md
    while IFS= read -r dir; do
      if [[ ! -f "${dir}/SKILL.md" ]]; then
        echo "missing SKILL.md in: ${dir}"; fail=1
      fi
    done < <(find "${ROOT}/skills" -mindepth 1 -maxdepth 1 -type d)

    # JSON validity + hook-command resolution. A hooks.json that parses but
    # points at scripts that do not exist is a silently dead enforcement layer,
    # which is the failure --check exists to catch.
    if command -v python3 >/dev/null 2>&1; then
      for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json \
               .codex-plugin/plugin.json hooks/hooks.json templates/settings.json; do
        if [[ -f "${ROOT}/${j}" ]] && ! python3 -m json.tool "${ROOT}/${j}" >/dev/null 2>&1; then
          echo "invalid JSON: ${j}"; fail=1
        fi
      done
      # The Codex manifest carries its hooks inline; the same check reads it.
      for j in hooks/hooks.json .codex-plugin/plugin.json; do
        if [[ -f "${ROOT}/${j}" && -f "${ROOT}/scripts/lib/check-hook-paths.py" ]]; then
          if ! hook_out=$(python3 "${ROOT}/scripts/lib/check-hook-paths.py" \
                            "${ROOT}/${j}" --root "${ROOT}" 2>&1); then
            echo "${hook_out}"; fail=1
          fi
        fi
      done
    else
      degraded="python3 not found — JSON validity and hook-command resolution were NOT checked"
    fi

    if [[ ${fail} -eq 0 ]]; then
      if [[ -n "${degraded}" ]]; then
        echo "WARN: ${degraded}"
        echo "LLM Orchestrator check: OK (degraded — see WARN above)"
      else
        echo "LLM Orchestrator check: OK"
      fi
    else
      echo "LLM Orchestrator check: FAILED"
    fi

    echo
    layers_report

    [[ ${fail} -eq 0 ]] || exit 1
    ;;

  --global)
    render_block "${HOME}/.claude/CLAUDE.md"
    echo "The block is rendered from templates/cadence-global-block.md; edit that file and re-run."
    echo
    layers_report
    ;;

  --codex)
    # Codex gets the cadence skill and the hooks from the Codex plugin
    # (.codex-plugin/plugin.json, through `codex plugin add`). This mode renders
    # the instructions block into ~/.codex/AGENTS.md, and removes the hook
    # entries and the skill copy an earlier --codex wrote, so each hook and the
    # skill are registered once. config.toml is never touched.
    # PREFLIGHT — every refusal fires before the first write, and the layers
    # report prints on every path.
    codex_refuse() { echo "refused: $1" >&2; echo >&2; layers_report >&2; exit 1; }
    hooks_file="${HOME}/.codex/hooks.json"
    agents_file="${HOME}/.codex/AGENTS.md"
    skills_dest="${HOME}/.agents/skills/cadence"
    old_hooks_lib="${ROOT}/scripts/lib/codex-old-hooks.py"

    # Removing the old install before the plugin is on would leave Codex with
    # no checks at all, so without the plugin nothing is removed.
    plugin_on=0; codex_plugin_on && plugin_on=1
    old_hooks=0
    if [[ "${plugin_on}" -eq 1 && -f "${hooks_file}" ]]; then
      command -v python3 >/dev/null 2>&1 || codex_refuse \
        "--codex needs python3 to check ${hooks_file} for hook entries an earlier --codex wrote. Install python3 and re-run; nothing was changed."
      if ! old_hooks=$(python3 "${old_hooks_lib}" count "${hooks_file}" "${ROOT}"); then
        old_hooks=0
        echo "${hooks_file} is not a hooks object this installer can read, so Codex cannot load it either; it was left alone and not checked for entries an earlier --codex wrote."
      fi
    fi
    if [[ "${old_hooks}" -gt 0 ]]; then
      hooks_res="$(resolve_target "${hooks_file}")"
      under_home "${hooks_res}" || codex_refuse \
        "${hooks_file} is a link to ${hooks_res}, which is outside ${HOME}, and it holds hook entries an earlier --codex wrote; remove them by hand. Nothing was changed."
      hooks_parent="${hooks_res%/*}"; [[ -n "${hooks_parent}" ]] || hooks_parent="/"
      if [[ ! -w "${hooks_res}" || ! -w "${hooks_parent}" || ! -x "${hooks_parent}" ]]; then
        codex_refuse "${hooks_res} (or its directory) is not writable by this user, so the hook entries an earlier --codex wrote cannot be removed; nothing was changed."
      fi
      if [[ "$(resolve_target "${agents_file}")" == "${hooks_res}" ]]; then
        codex_refuse "${hooks_file} and ${agents_file} are the same file (${hooks_res}); nothing was changed."
      fi
    fi

    # The skill copy an earlier --codex wrote carries a marker at its root. A
    # cadence skill without it is the person's and is left alone.
    old_skill=""
    if [[ "${plugin_on}" -eq 1 && -e "${skills_dest}" ]]; then
      skills_res="$(resolve_target "${skills_dest}")"
      if [[ -d "${skills_res}" && ! ( -r "${skills_res}" && -w "${skills_res}" && -x "${skills_res}" ) ]]; then
        codex_refuse "${skills_dest} cannot be read, written or entered by this user, so it cannot be checked for a skill copy an earlier --codex wrote; fix its permissions, then re-run; nothing was changed."
      fi
      if [[ -f "${skills_res}/.orch-installed" ]]; then
        under_home "${skills_res}" || codex_refuse \
          "${skills_dest} is a link to ${skills_res}, which is outside ${HOME}; remove the skill copy there by hand. Nothing was changed."
        # Every directory in the copy must be emptied, so each must be
        # readable, writable and enterable. A scan that fails is a refusal.
        scan="$(mktemp "${TMPDIR:-/tmp}/orch-scan.XXXXXX")" \
          || codex_refuse "no temporary file could be created under ${TMPDIR:-/tmp}; set TMPDIR to a writable directory and re-run; nothing was changed."
        if ! find "${skills_res}" -type d \( ! -perm -u+w -o ! -perm -u+x -o ! -perm -u+r \) > "${scan}" 2>/dev/null \
           || [[ -s "${scan}" ]]; then
          locked=$(head -3 "${scan}" | tr '\n' ' '); rm -f "${scan}"
          codex_refuse "${skills_dest} holds a directory this user cannot write, enter or read (${locked:-${skills_dest}}), so the skill copy an earlier --codex wrote cannot be removed; fix its permissions, then re-run; nothing was changed."
        fi
        rm -f "${scan}"
        old_skill="${skills_res}"
      fi
    fi

    # The block render has refusals of its own (duplicate markers, a dangling
    # link, a marker pair the person wrote); ask them all now, writing nothing.
    d="${HOME}/.codex"
    if [[ -L "${d}" && ! -e "${d}" ]]; then
      codex_refuse "${d} is a link that resolves to nothing ($(readlink "${d}")); fix the link; nothing was changed."
    fi
    if [[ -e "${d}" ]]; then
      d_res="$(resolve_target "${d}")"
      under_home "${d_res}" || codex_refuse "${d} is a link to ${d_res}, which is outside ${HOME}; nothing was changed."
      [[ -d "${d_res}" && -w "${d_res}" && -x "${d_res}" ]] || codex_refuse "${d} is not a writable directory; nothing was changed."
    else
      [[ -d "${HOME}" && -w "${HOME}" && -x "${HOME}" ]] || codex_refuse "${HOME} is not writable, so ${d} cannot be created; nothing was changed."
    fi
    if ! RENDER_CHECK_ONLY=1 render_block "${agents_file}"; then
      codex_refuse "${agents_file} cannot take the cadence block (see above); nothing was changed."
    fi

    # Writes: the old hook entries, the block, then the old skill copy.
    if [[ "${old_hooks}" -gt 0 ]]; then
      python3 "${old_hooks_lib}" remove "${hooks_res}" "${ROOT}" || codex_refuse \
        "the hook entries an earlier --codex wrote could not be removed from ${hooks_file}; nothing was changed."
    fi
    render_block "${agents_file}"

    # Only files this plugin ships, at the paths it ships them, are deleted;
    # anything else in the copy is the person's and is named and kept.
    if [[ -n "${old_skill}" ]]; then
      failed=""
      while IFS= read -r f; do
        if [[ -f "${old_skill}/${f}" && ! -L "${old_skill}/${f}" ]]; then
          rm -f "${old_skill}/${f}" 2>/dev/null || failed="${failed} ${f}"
        fi
      done < <(cd "${ROOT}/skills/cadence" && find . -type f | sed 's|^\./||'; \
               echo scripts/lib/orch-task-resources.py; echo .orch-installed)
      find "${old_skill}" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
      if [[ -n "${failed}" ]]; then
        echo "error: these files of the skill copy in ${skills_dest} could not be deleted:${failed}. Delete them by hand, or Codex lists the cadence skill twice." >&2
        exit 1
      fi
      if [[ -e "${old_skill}" ]]; then
        kept=$(cd "${old_skill}" && find . -mindepth 1 ! -type d | sed 's|^\./||' | tr '\n' ' ')
        echo "removed the skill copy an earlier --codex wrote from ${skills_dest}; kept files this plugin did not ship: ${kept}"
      else
        [[ -L "${skills_dest}" ]] && rm -f "${skills_dest}"
        echo "removed the skill copy an earlier --codex wrote from ${skills_dest}"
      fi
    elif [[ "${plugin_on}" -eq 1 && -e "${skills_dest}" ]]; then
      echo "${skills_dest} is a cadence skill this installer did not write, so it was left in place. Codex lists it next to the plugin's cadence skill; remove it if it is an old copy."
    fi

    echo
    if [[ "${plugin_on}" -eq 1 ]]; then
      echo "The cadence skill and the hooks come from the Codex plugin, which is installed."
    else
      echo "The cadence skill and the hooks come from the Codex plugin, which is not installed in ${HOME}/.codex. Until it is, nothing an earlier --codex wrote is removed, so its hooks keep working. To finish, add the plugin first, then run --codex again:"
      echo "  codex plugin marketplace add ${ROOT}"
      echo "  codex plugin add llm-orchestrator@llm-orchestrator"
      echo "  ${ROOT}/scripts/install.sh --codex"
    fi
    echo "Then open /hooks in a new Codex session and trust the three hooks. Installing does not grant hook trust. config.toml was not changed. See docs/codex.md."
    echo
    layers_report
    ;;

  --link)
    target="${HOME}/.claude/llm-orchestrator"
    mkdir -p "$(dirname "${target}")"
    if [[ -e "${target}" || -L "${target}" ]]; then
      echo "target already exists: ${target}"; exit 1
    fi
    ln -s "${ROOT}" "${target}"
    echo "Linked ${ROOT} -> ${target}"
    ;;

  --copy)
    dest="${2:-}"
    if [[ -z "${dest}" ]]; then
      echo "usage: $0 --copy <project-dir>"; exit 1
    fi
    if [[ ! -d "${dest}" ]]; then
      echo "no such directory: ${dest}"; exit 1
    fi
    # Resolve to an absolute path FIRST. The rewrite below claims the result is
    # absolute, which is only true when the prefix itself is — a relative dest
    # would bake relative hook paths into hooks.json.
    dest="$(cd "${dest}" && pwd)"
    mkdir -p "${dest}/.claude" "${dest}/.claude/scripts/hooks" "${dest}/.claude/scripts/lib" "${dest}/.claude/scripts/verification" "${dest}/.claude/docs"
    cp -R "${ROOT}/skills" "${dest}/.claude/"
    cp -R "${ROOT}/commands" "${dest}/.claude/"
    cp -R "${ROOT}/templates" "${dest}/.claude/"
    cp -R "${ROOT}/agents" "${dest}/.claude/" 2>/dev/null || true
    cp -R "${ROOT}/output-styles" "${dest}/.claude/" 2>/dev/null || true
    cp -R "${ROOT}/hooks" "${dest}/.claude/"
    # Copy hook scripts and statusline.
    for f in "${ROOT}/scripts/hooks/"*.sh "${ROOT}/scripts/hooks/"*.py; do
      [[ -f "${f}" ]] && cp "${f}" "${dest}/.claude/scripts/hooks/"
    done
    [[ -f "${ROOT}/scripts/statusline.sh" ]] && cp "${ROOT}/scripts/statusline.sh" "${dest}/.claude/scripts/"
    [[ -f "${ROOT}/scripts/protocol-lint.sh" ]] && cp "${ROOT}/scripts/protocol-lint.sh" "${dest}/.claude/scripts/"
    [[ -f "${ROOT}/scripts/orch-worktree-materialize.sh" ]] && cp "${ROOT}/scripts/orch-worktree-materialize.sh" "${dest}/.claude/scripts/"
    [[ -f "${ROOT}/scripts/orch-worktree-integrate.sh" ]] && cp "${ROOT}/scripts/orch-worktree-integrate.sh" "${dest}/.claude/scripts/"
    # Copy EVERY lib, not only the shell ones. This loop was `*.sh` and the two
    # PreToolUse guards source scripts/lib/orch-git-classify.py — so a --copy
    # install shipped both guards with their semantic classifier missing, and
    # they silently fell back to spelling rules. `git reset --har HEAD~1` and
    # `git commit --no-verif` were BLOCKED from the source tree and ALLOWED from
    # an install. The verifier could not see it: check-hook-paths.py and
    # test-install.sh both assert hooks.json command paths, and a transitive
    # dependency is not one — the check shared the blind spot of the thing it
    # checked. tests/test-install.sh now asserts installed-vs-source lib parity
    # AND runs a classifier-only bypass against the installed guard.
    for f in "${ROOT}/scripts/lib/"*; do
      [[ -f "${f}" ]] && cp "${f}" "${dest}/.claude/scripts/lib/"
    done
    # Copy the protocol doc so the meta-skill's relative link resolves.
    cp "${ROOT}/concise-agent-protocol.md" "${dest}/.claude/" 2>/dev/null || true
    # Ship the install doc: the generated settings.json's _hooks_note points at
    # it, and docs/ is otherwise not part of a --copy install — the pointer
    # would dangle.
    cp "${ROOT}/docs/install.md" "${dest}/.claude/docs/" 2>/dev/null || true
    # dispatching-subagents points at this for model/effort guidance; without it
    # the reference dangles in every --copy install.
    cp "${ROOT}/docs/anthropic-ecosystem.md" "${dest}/.claude/docs/" 2>/dev/null || true

    sed_inplace() {
      if sed --version >/dev/null 2>&1; then
        sed -i "$@"  # GNU
      else
        sed -i '' "$@"  # BSD/macOS
      fi
    }
    # Rewrite hook paths so they resolve without CLAUDE_PLUGIN_ROOT.
    # BOTH spellings: hooks.json writes braced ${CLAUDE_PLUGIN_ROOT}, and the
    # original bare-$ pattern here matched neither brace — every --copy install
    # shipped a dead enforcement layer while this script printed success.
    # Escape sed-special characters in the replacement so an unusual dest
    # cannot corrupt the rewrite.
    dest_esc=$(printf '%s' "${dest}" | sed 's/[&|\\]/\\&/g')
    sed_inplace \
      -e "s|\${CLAUDE_PLUGIN_ROOT}|${dest_esc}/.claude|g" \
      -e "s|\$CLAUDE_PLUGIN_ROOT|${dest_esc}/.claude|g" \
      "${dest}/.claude/hooks/hooks.json"

    # Verify before claiming. The rewrite is only reported as done when every
    # command hook in the INSTALLED hooks.json is an absolute path that exists.
    installed_hooks="${dest}/.claude/hooks/hooks.json"
    if command -v python3 >/dev/null 2>&1; then
      if ! verify_out=$(python3 "${ROOT}/scripts/lib/check-hook-paths.py" "${installed_hooks}" 2>&1); then
        echo "ERROR: hook-path rewrite did not produce a working install:" >&2
        printf '%s\n' "${verify_out}" >&2
        exit 1
      fi
      rewrite_msg="Hook paths rewritten to absolute (verified: every command path exists on disk)."
    else
      # Weaker fallback without python3: at least no placeholder text of any
      # spelling may survive. Say exactly what was and was not verified.
      if grep -q 'CLAUDE_PLUGIN_ROOT' "${installed_hooks}"; then
        echo "ERROR: hook-path rewrite left CLAUDE_PLUGIN_ROOT placeholders in ${installed_hooks}" >&2
        exit 1
      fi
      rewrite_msg="Hook paths rewritten to absolute (python3 not found — placeholder removal checked, path existence NOT verified)."
    fi

    # Seed settings.json from the shipped template (permissions + ORCH knobs),
    # rather than a hand-written stub that discards it. Never overwrite an
    # existing settings.json.
    if [[ ! -f "${dest}/.claude/settings.json" ]]; then
      cp "${ROOT}/templates/settings.json" "${dest}/.claude/settings.json"
      settings_msg="Seeded ${dest}/.claude/settings.json from templates/settings.json."
    else
      settings_msg="Kept existing ${dest}/.claude/settings.json (not overwritten)."
    fi

    echo "Copied LLM Orchestrator into ${dest}/.claude/"
    echo "${rewrite_msg}"
    echo "${settings_msg}"
    echo "Set ORCH_HOME if you want memory in a different location (defaults to ~/.llm-orchestrator)."
    echo
    echo "NEXT STEP: to fire hooks, either install as a Claude Code plugin OR"
    echo "          add the hook entries to ${dest}/.claude/settings.json — see"
    echo "          ${dest}/.claude/docs/install.md ('Wiring hooks for a --copy install')."
    ;;

  *)
    cat <<USAGE
LLM Orchestrator installer

  $0 --check                verify the local checkout is sane
  $0 --link                 symlink this repo into ~/.claude/llm-orchestrator
  $0 --copy <project-dir>   copy into <project-dir>/.claude/
  $0 --global               render the cadence block into ~/.claude/CLAUDE.md
  $0 --codex                render the same block into ~/.codex/AGENTS.md (the Codex plugin brings the skill and hooks)
USAGE
    exit 1
    ;;
esac
