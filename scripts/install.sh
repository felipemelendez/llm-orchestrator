#!/usr/bin/env bash
# LLM Orchestrator installer / verifier.
# Usage:
#   ./scripts/install.sh --check         verify the local checkout is sane
#   ./scripts/install.sh --link          symlink into ~/.claude/llm-orchestrator
#   ./scripts/install.sh --copy <dir>    copy skills/commands/templates into <dir>/.claude/
#
# Scope note: --check validates the SOURCE CHECKOUT it lives in — never an
# installed tree (install.sh is not among the files --copy writes, so it cannot
# be pointed at one). A --copy install is verified at install time instead:
# --copy fails, rather than printing success, if the hook-path rewrite did not
# produce absolute paths that exist on disk.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cmd="${1:-}"
case "${cmd}" in
  --check)
    fail=0
    degraded=""
    for f in README.md AGENTS.md CLAUDE.md concise-agent-protocol.md ARCHITECTURE.md \
             .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
      if [[ ! -f "${ROOT}/${f}" ]]; then
        echo "missing: ${f}"; fail=1
      fi
    done
    for d in skills commands agents templates hooks workflows scripts/hooks scripts/lib output-styles docs examples tests; do
      if [[ ! -d "${ROOT}/${d}" ]]; then
        echo "missing dir: ${d}"; fail=1
      fi
    done

    # Non-hook infrastructure. Hook SCRIPTS are deliberately absent from this
    # list: they are derived from hooks/hooks.json below, because the previous
    # hand-maintained copy of that list drifted two entries behind reality and
    # --check kept saying OK with shipped hooks deleted.
    for f in scripts/lib/orch-lock.sh scripts/lib/orch-protocol.sh scripts/lib/orch-handoff.sh \
             scripts/lib/orch-project.sh scripts/lib/orch-signals.sh scripts/lib/orch-evidence.sh \
             scripts/lib/orch-json.sh scripts/lib/orch-arch.sh scripts/lib/orch-regression.sh \
             scripts/lib/orch-detect.sh scripts/lib/check-hook-paths.py \
             scripts/orch-worktree-materialize.sh scripts/orch-worktree-integrate.sh \
             scripts/statusline.sh scripts/protocol-lint.sh output-styles/orchestrator.md \
             docs/install.md templates/settings.json workflows/review-diff.js \
             skills/brainstorming/scripts/server.cjs skills/using-orchestrator/SKILL.md; do
      if [[ ! -f "${ROOT}/${f}" ]]; then
        echo "missing: ${f}"; fail=1
      fi
    done

    # Commands and agents ship without a wiring manifest, so this list is the
    # manifest. It fails closed on deletion (the reproduced blind spot); a new
    # command/agent must be appended here to be guarded.
    for f in agents/orch-code-reviewer.md agents/orch-debugger.md agents/orch-explorer.md \
             agents/orch-implementer.md agents/orch-researcher.md agents/orch-security-reviewer.md \
             agents/orch-spec-reviewer.md \
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
               hooks/hooks.json templates/settings.json; do
        if [[ -f "${ROOT}/${j}" ]] && ! python3 -m json.tool "${ROOT}/${j}" >/dev/null 2>&1; then
          echo "invalid JSON: ${j}"; fail=1
        fi
      done
      if [[ -f "${ROOT}/hooks/hooks.json" && -f "${ROOT}/scripts/lib/check-hook-paths.py" ]]; then
        if ! hook_out=$(python3 "${ROOT}/scripts/lib/check-hook-paths.py" \
                          "${ROOT}/hooks/hooks.json" --root "${ROOT}" 2>&1); then
          echo "${hook_out}"; fail=1
        fi
      fi
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
      exit 1
    fi
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
    mkdir -p "${dest}/.claude" "${dest}/.claude/scripts/hooks" "${dest}/.claude/scripts/lib" "${dest}/.claude/docs"
    cp -R "${ROOT}/skills" "${dest}/.claude/"
    cp -R "${ROOT}/commands" "${dest}/.claude/"
    cp -R "${ROOT}/templates" "${dest}/.claude/"
    cp -R "${ROOT}/agents" "${dest}/.claude/" 2>/dev/null || true
    cp -R "${ROOT}/output-styles" "${dest}/.claude/" 2>/dev/null || true
    cp -R "${ROOT}/hooks" "${dest}/.claude/"
    # Workflow scripts. requesting-code-review and commands/review.md both name
    # workflows/review-diff.js; without this the installed skills point at a file
    # that does not exist.
    cp -R "${ROOT}/workflows" "${dest}/.claude/"
    # Copy hook scripts and statusline.
    for f in "${ROOT}/scripts/hooks/"*.sh; do
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
USAGE
    exit 1
    ;;
esac
