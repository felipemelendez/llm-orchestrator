#!/usr/bin/env bash
# LLM Orchestrator installer / verifier.
# Usage:
#   ./scripts/install.sh --check         verify the local checkout is sane
#   ./scripts/install.sh --link          symlink into ~/.claude/llm-orchestrator
#   ./scripts/install.sh --copy <dir>    copy skills/commands/templates into <dir>/.claude/
#   ./scripts/install.sh --global        render the cadence block into ~/.claude/CLAUDE.md
#   ./scripts/install.sh --codex         the same block, plus the skill and the hook, for Codex
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
  printf '%s' "${p}"
}

# The first free backup name. A `.bak` written on every run holds the state of
# the LAST run, not the state before this installer ever touched the file.
backup_name() {
  local b="$1.bak" n=1
  while [[ -e "${b}" ]]; do b="$1.bak.${n}"; n=$((n+1)); done
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
  mkdir -p "$(dirname "${target}")"
  if [[ -L "${target}" && ! -e "${target}" ]]; then
    echo "refused: ${target} is a link that resolves to nothing ($(readlink "${target}")) — fix the link; nothing was written" >&2
    return 1
  fi
  resolved="$(resolve_target "${target}")"
  if [[ "${resolved}" != "${target}" ]]; then
    case "${resolved}" in
      "${HOME}"/*) ;;
      *) echo "refused: ${target} is a link to ${resolved}, which is outside ${HOME} — this installer writes only under HOME; nothing was written" >&2
         return 1 ;;
    esac
    mkdir -p "$(dirname "${resolved}")"
  fi
  target="${resolved}"
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
    local reg="${target}.orch-region.$$" cur="${target}.orch-cur.$$" rc=0
    if [[ $((eline - sline)) -gt 1 ]]; then
      sed -n "$((sline + 1)),$((eline - 1))p" "${target}" > "${reg}"
    else
      : > "${reg}"
    fi
    _block_interior "${BLOCK_SRC}" > "${cur}"
    if cmp -s "${reg}" "${cur}"; then
      rm -f "${reg}" "${cur}"
      echo "rendered ${target} (unchanged)"
      return 0
    fi
    if ! _region_genuine "${reg}"; then
      rm -f "${reg}" "${cur}"
      echo "refused: ${target} lines ${sline}-${eline} carry the cadence markers around text this installer did not write — it will not replace text it cannot prove is its own. Move the sample out of ~/.claude/CLAUDE.md, or delete those two marker lines, then re-run. Nothing was written." >&2
      return 1
    fi
    rm -f "${reg}" "${cur}"
    bak="$(backup_name "${target}")"
    cp "${target}" "${bak}"
  fi
  tmp="${target}.orch-render.$$"
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

# The layers report — READ ONLY, and it honours HOME from the environment. Five
# yes/no lines, because "is the cadence actually on here?" is otherwise five
# separate things to remember.
_has_block() { [[ -f "$1" ]] && grep -qF "${BLOCK_START}" "$1" 2>/dev/null && echo yes || echo no; }
# "names the adapter" is not the question — "names an adapter that is still
# there" is. A checkout that moved leaves the string in place and the hook dead.
_names_adapter() {
  local p
  [[ -f "$1" ]] || { echo no; return 0; }
  p=$(grep -oE '/[^"]*codex-cadence-adapter\.sh' "$1" 2>/dev/null | head -1 || true)
  if [[ -z "${p}" ]]; then
    grep -q 'codex-cadence-adapter' "$1" 2>/dev/null && echo "yes (no absolute path)" || echo no
  elif [[ -f "${p}" ]]; then
    echo yes
  else
    echo "stale path (${p} does not exist — re-run --codex)"
  fi
}
layers_report() {
  local h="${HOME:-}" proj="${CLAUDE_PROJECT_DIR:-${PWD}}"
  echo "layers present on this machine:"
  printf '  %-44s %s\n' "${h}/.claude/CLAUDE.md cadence block:" "$(_has_block "${h}/.claude/CLAUDE.md")"
  printf '  %-44s %s\n' "${h}/.codex/AGENTS.md cadence block:" "$(_has_block "${h}/.codex/AGENTS.md")"
  printf '  %-44s %s\n' "${h}/.agents/skills/cadence:" \
    "$([[ -d "${h}/.agents/skills/cadence" ]] && echo yes || echo no)"
  printf '  %-44s %s\n' "${h}/.codex/hooks.json names the adapter:" "$(_names_adapter "${h}/.codex/hooks.json")"
  printf '  %-44s %s\n' "${proj}/docs/llm-orchestrator/cadence.json:" \
    "$([[ -f "${proj}/docs/llm-orchestrator/cadence.json" ]] && echo yes || echo no)"
}

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
             skills/brainstorming/scripts/server.cjs skills/using-orchestrator/SKILL.md \
             skills/cadence/SKILL.md skills/cadence/CADENCE.md \
             skills/cadence/scripts/orch-cadence-gate.sh skills/cadence/scripts/orch-cadence-check.sh \
             skills/cadence/scripts/cadence-detect.sh skills/cadence/scripts/cadence-init.sh \
             skills/cadence/references/commit-msg skills/cadence/references/cadence-state.md \
             templates/cadence-global-block.md scripts/hooks/codex-cadence-adapter.sh; do
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
    # Three layers, in this order: the skill, the instructions block, the hook.
    # config.toml is never touched — hooks.json is the file this installer owns.
    # PREFLIGHT — every refusal fires before the first write, and the layers
    # report prints on every path. A run that copies the skill, renders the
    # block and THEN refuses leaves the machine in a state nobody chose.
    codex_refuse() { echo "refused: $1" >&2; echo >&2; layers_report >&2; exit 1; }
    skills_dest="${HOME}/.agents/skills/cadence"
    hooks_file="${HOME}/.codex/hooks.json"
    adapter="${ROOT}/scripts/hooks/codex-cadence-adapter.sh"

    command -v python3 >/dev/null 2>&1 || codex_refuse \
      "--codex needs python3 to merge the Codex hooks file without destroying what is already in it. Install python3 and re-run; nothing was changed."
    [[ -f "${adapter}" ]] || codex_refuse \
      "${adapter} is missing — nothing was written to the Codex hooks file."
    if [[ -e "${skills_dest}" && ! -f "${skills_dest}/.orch-installed" ]]; then
      codex_refuse "${skills_dest} exists and this installer did not write it (no .orch-installed marker inside). Move it aside yourself if you want it replaced; nothing was changed."
    fi
    if [[ -f "${hooks_file}" ]]; then
      if ! python3 -m json.tool "${hooks_file}" >/dev/null 2>&1; then
        codex_refuse "${hooks_file} does not parse as JSON. Fix it or move it aside and re-run; nothing was changed."
      fi
      # Parsing is not the shape the merge needs. An array or a scalar parses,
      # and refusing it only at the merge leaves the skill copied and AGENTS.md
      # rendered — writes nobody chose, after a refusal. Same line, earlier.
      if ! python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(open(sys.argv[1])), dict) else 1)' \
           "${hooks_file}" >/dev/null 2>&1; then
        codex_refuse "${hooks_file} is not a JSON object; nothing was changed."
      fi
    fi
    mkdir -p "${HOME}/.codex" "${HOME}/.agents" 2>/dev/null || true
    for d in "${HOME}/.codex" "${HOME}/.agents"; do
      [[ -d "${d}" ]] || codex_refuse "${d} could not be created; nothing was changed."
      [[ -w "${d}" ]] || codex_refuse "${d} is not writable by this user; nothing was changed."
    done

    if [[ -e "${skills_dest}" ]]; then
      # Say what goes before it goes. The marker says "safe to delete"; a
      # person's own notes inside the copy are not, and they are about to be.
      echo "replacing the previous skill copy at ${skills_dest}; these files go with it:"
      find "${skills_dest}" -type f | sed "s|^|  |"
      rm -rf "${skills_dest}"
    fi
    mkdir -p "$(dirname "${skills_dest}")"
    cp -R "${ROOT}/skills/cadence" "${skills_dest}"
    printf 'written by llm-orchestrator install.sh --codex — safe to delete\n' \
      > "${skills_dest}/.orch-installed"
    echo "copied the cadence skill into ${skills_dest} — it is a copy, not a link: re-run --codex after updating the plugin."

    render_block "${HOME}/.codex/AGENTS.md"

    # The hook entry. The adapter is Codex's substitute for the file-deny rules
    # Claude Code has natively, and nothing more: a Bash command or an
    # apply_patch header that names a locked FILE and is not one plain read is
    # refused. Everything else about the lock — the directories, the marked
    # laws section, a path a command assembles at runtime — is the alarm's:
    # the session-start line, the end-of-turn verdict, the commit-msg hook and
    # --audit in CI. Codex sends tool_name and tool_input.command and no file
    # path, so the adapter is registered for Bash and for apply_patch and reads
    # the patch headers out of the command string. The hooks.json entry SHAPE
    # and the apply_patch matcher name are unverified against a live Codex;
    # this is what the documentation describes, and the git layer is the
    # enforcement that does not depend on it.
    if [[ -L "${hooks_file}" && ! -e "${hooks_file}" ]]; then
      codex_refuse "${hooks_file} is a link that resolves to nothing ($(readlink "${hooks_file}")); nothing was changed."
    fi
    hooks_res="$(resolve_target "${hooks_file}")"
    if [[ "${hooks_res}" != "${hooks_file}" ]]; then
      case "${hooks_res}" in
        "${HOME}"/*) echo "${hooks_file} is a link to ${hooks_res}; writing through it." ;;
        *) codex_refuse "${hooks_file} is a link to ${hooks_res}, which is outside ${HOME}; nothing was changed." ;;
      esac
    fi
    hooks_file="${hooks_res}"
    mkdir -p "$(dirname "${hooks_file}")"
    python3 - "${hooks_file}" "${adapter}" <<'PY'
import json, os, sys

path, cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as exc:
        sys.stderr.write(
            "refused: %s does not parse as JSON (%s). Fix it or move it aside; "
            "nothing was changed (a .bak copy is beside it).\n" % (path, exc))
        sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("refused: %s is not a JSON object; nothing was changed.\n" % path)
    sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    sys.stderr.write("refused: the \"hooks\" key of %s is not an object; nothing was changed.\n" % path)
    sys.exit(1)
pre = hooks.get("PreToolUse")
if not isinstance(pre, list):
    pre = []


def ours(entry):
    # ONLY this file's own basename. The plugin's name is an ordinary path
    # word: a person whose notes live in ~/llm-orchestrator-notes/ has their
    # own hook silently deleted by a name test any looser than this one.
    if not isinstance(entry, dict):
        return False
    c = entry.get("command", "")
    if not isinstance(c, str):
        return False
    return any(part.rsplit("/", 1)[-1] == "codex-cadence-adapter.sh"
               for part in c.split())


# Dedup: every previous entry of ours is REPLACED, never added beside. A second
# --codex must leave exactly one adapter registration per matcher.
kept = []
for group in pre:
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        kept.append(group)
        continue
    keep = [h for h in group["hooks"] if not ours(h)]
    if len(keep) == len(group["hooks"]):
        kept.append(group)
    elif keep:
        group["hooks"] = keep
        kept.append(group)

for matcher in ("Bash", "apply_patch"):
    kept.append({"matcher": matcher,
                 "hooks": [{"type": "command", "command": cmd}]})

hooks["PreToolUse"] = kept
data["hooks"] = hooks
new = json.dumps(data, indent=2) + "\n"

old = ""
if os.path.exists(path):
    try:
        old = open(path).read()
    except Exception:
        old = ""
if old == new:
    print("%s already carries the adapter hook (unchanged, no backup written)" % path)
    sys.exit(0)

# The backup is the state BEFORE this installer ever touched the file. A .bak
# rewritten on every run holds the previous run's merge, not the original.
if old:
    bak = path + ".bak"
    n = 1
    while os.path.exists(bak):
        bak = "%s.bak.%d" % (path, n)
        n += 1
    with open(bak, "w") as fh:
        fh.write(old)
    print("backed up %s to %s" % (path, bak))

tmp = path + ".orch-merge.tmp"
with open(tmp, "w") as fh:
    fh.write(new)
os.replace(tmp, path)
print("merged the adapter hook into %s (matchers Bash and apply_patch)" % path)
PY
    echo "The adapter is Codex's substitute for the file-deny rules Claude Code has natively, and nothing more: a Bash command or an apply_patch header that names a locked FILE and is not one plain read is refused, with the way out printed. It does not guard directories, the marked laws section, links, or a path a command assembles at runtime — the alarm names those instead: the session-start line, the end-of-turn verdict, the commit-msg hook, and --audit in CI."
    echo "The matchers are Bash and apply_patch, the two the Codex hooks documentation names; project-local hooks load only when the project's own Codex layer is trusted. Two things are UNVERIFIED against a live Codex and stay so: whether a PreToolUse hook fires inside a Codex subagent, and whether a matcher can be aimed at a patch's target path rather than the tool. The git layer is the enforcement that depends on neither."
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
  $0 --global               render the cadence block into ~/.claude/CLAUDE.md
  $0 --codex                the cadence skill, the same block and the hook, for Codex
USAGE
    exit 1
    ;;
esac
