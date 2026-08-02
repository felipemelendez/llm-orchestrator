#!/usr/bin/env bash
# orch-evidence.sh — shared helpers for the verification evidence ledger.
#
# The ledger is written EXCLUSIVELY by the PostToolUse hook
# (orch-evidence-ledger.sh): one TSV line per verify-shaped Bash command the
# harness actually executed. Because the hook — not the model — computes and
# records the row, a completion claim can be checked against recorded reality
# instead of trusted. This closes the fabrication path where the model writes a
# plausible `Verify:` line for a command it never ran (MAST FM-2.6,
# reasoning-action mismatch).
#
# PRIMARY CHECK IS THE TURN WINDOW, not a cited stamp. The gate asks: "did a
# verify-shaped command actually run green between this turn's start and now?"
# The model is not in that loop at all — it cannot opt out by declining to
# cite, cannot cite a stale stamp from three turns ago, and never sees any
# marker text. Stamp citation remains supported for cross-agent evidence
# transport when ORCH_EVIDENCE_MARKER=1, but nothing depends on it.
#
# Honest boundary: this defeats fabrication/hallucination, not a deliberately
# adversarial model — an agent with arbitrary shell could append to the ledger
# file itself. The threat here is a model that *narrates* verification it
# didn't do, and that model does not run multi-step ledger forgeries. It also
# says nothing about whether the verify command was the RIGHT one, or whether
# the suite covers the change. `substance` closes only the narrowest of those
# gaps: a green run that executed no tests.
#
# Ledger line format (TSV):
#   <stamp>\t<exit>\t<epoch>\t<substance>\t<command-first-160>
# where substance ∈ ok | none (explicitly ran zero tests) | red.
# Ledger path: ${ORCH_HOME}/state/<project-hash>/evidence.<session_id>.tsv
#
# Bash 3.2 compatible. No external deps beyond grep/awk/shasum-or-cksum.

# orch_evidence_state_dir
# Prints the project state directory. Requires orch-project.sh to be sourced
# (for orch_project_hash); falls back to the "default" hash.
orch_evidence_state_dir() {
  local home hash
  home="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  hash="default"
  declare -f orch_project_hash >/dev/null 2>&1 && hash=$(orch_project_hash 2>/dev/null || echo default)
  printf '%s/state/%s' "${home}" "${hash}"
}

# orch_evidence_ledger_path <session_id>
orch_evidence_ledger_path() {
  printf '%s/evidence.%s.tsv' "$(orch_evidence_state_dir)" "$1"
}

# orch_turn_start_path <session_id>
# The epoch at which the current user turn began, written by the
# UserPromptSubmit hook. Absent on the first turn of a resumed session, or when
# that hook is disabled — callers must treat absence as "window unknown".
orch_turn_start_path() {
  printf '%s/turn-start.%s' "$(orch_evidence_state_dir)" "$1"
}

# orch_turn_start <session_id>
# Prints the turn-start epoch, or nothing when unknown.
orch_turn_start() {
  local p
  p=$(orch_turn_start_path "$1")
  [[ -f "${p}" ]] || return 0
  head -1 "${p}" 2>/dev/null | tr -cd '0-9'
}

# orch_evidence_window <session_id> <since_epoch>
# Reports on verify runs recorded at or after <since_epoch>. Prints a one-line
# reason on any non-zero return.
#
# Reads ONLY this session's ledger. An earlier draft fell back to sibling
# ledgers in the same project state dir, on the theory that a subagent might
# have run the tests under its own session id. That fallback was removed: it
# let a green row from any concurrent session in the same project satisfy this
# session's claim — a FALSE ALL-CLEAR, which is the one error direction that
# matters here. Silence when we know nothing is safe; "verified" when we do not
# know is not. If subagents ever do get distinct session ids, this degrades to
# rc 2 (silent), never to a wrong verdict.
#
# Return codes:
#   0 — a verify command ran green with real output inside the window
#   1 — HARD: the most recent verify run in the window FAILED
#   2 — SOFT: no verify run recorded in the window (may be a custom command
#       outside ORCH_SIG_VERIFY_CMD, or the ledger hook is disabled)
#   3 — SOFT: the run was green but verified nothing (zero tests / no output)
orch_evidence_window() {
  local sid="$1" since="$2" dir ledger rows

  [[ -n "${since}" ]] || { printf 'turn window unknown\n'; return 2; }
  dir=$(orch_evidence_state_dir)
  [[ -d "${dir}" ]] || { printf 'no evidence ledger for this project\n'; return 2; }

  ledger="${dir}/evidence.${sid}.tsv"
  rows=""
  [[ -f "${ledger}" ]] && rows=$(awk -F'\t' -v s="${since}" '$3+0 >= s+0' "${ledger}" 2>/dev/null)
  if [[ -z "${rows}" ]]; then
    printf 'no verify-shaped command was recorded this turn\n'
    return 2
  fi

  # An unresolved RED outranks a later green from a DIFFERENT command.
  #
  # Taking only the latest row meant the normal fix-then-lint workflow erased a
  # failure: `pytest` red, then `tsc --noEmit` green, and the gate went quiet on
  # a claim the test suite still rejects. A red is answered only by a later green
  # of the SAME command — that is what "I fixed it and re-ran" looks like.
  local unresolved
  # Keyed on the RUNNER, not the verbatim command. `pytest tests/test_x.py -q`
  # going red and then `pytest -q` going green is the canonical TDD sequence —
  # narrow red, broad green — and keying on the full string reported it as an
  # unresolved failure, which is hard and blocks under strict. A later green from
  # the same runner answers an earlier red from that runner.
  # A green answers a red when it ran the same runner over the same ground or
  # MORE of it. `pytest tests/test_x.py -q` red then `pytest -q` green is the
  # canonical TDD sequence (narrow red, broad green) and must resolve; keying on
  # the verbatim command reported it as an unresolved failure, which blocks under
  # strict. But `pytest tests/smoke` green must NOT answer `pytest tests/unit`
  # red — different ground. So: a green with no path arguments covers everything
  # from that runner; a green with paths covers only a red whose paths it contains.
  unresolved=$(printf '%s\n' "${rows}" | awk -F'\t' '
    function runner(c,   n, w, i, t) {
      n = split(c, w, /[ \t]+/); t = w[1]
      for (i = 1; i <= n; i++) { t = w[i]
        if (t != "cd" && t !~ /=/ && t != "sudo" && t != "env" && t != "time") break }
      return t }
    function args(c,   n, w, i, a) {
      n = split(c, w, /[ \t]+/); a = ""
      for (i = 2; i <= n; i++) if (w[i] !~ /^-/) a = a " " w[i] " "
      return a }
    function covers(g, r,   n, w, i) {   # green args cover red args?
      if (g ~ /^ *$/) return 1
      n = split(r, w, /[ \t]+/)
      for (i = 1; i <= n; i++) if (w[i] != "" && index(g, " " w[i] " ") == 0) return 0
      return 1 }
    { ep = $3 + 0; t = runner($5)
      if ($2 == "0") { gn[t] = gn[t] "\n" ep "\t" args($5) }
      else if (ep >= red_ep[t]) { red_ep[t] = ep; red_args[t] = args($5); red_line[t] = $0 } }
    END {
      for (t in red_line) {
        resolved = 0
        n = split(gn[t], gl, "\n")
        for (i = 1; i <= n; i++) {
          if (gl[i] == "") continue
          split(gl[i], f, "\t")
          if (f[1] + 0 >= red_ep[t] && covers(f[2], red_args[t])) { resolved = 1; break } }
        if (!resolved) { print red_line[t]; exit } } }')
  if [[ -n "${unresolved}" ]]; then
    printf 'a verification run this turn FAILED and was never re-run green: `%s`\n' "$(printf '%s' "${unresolved}" | cut -f5)"
    return 1
  fi

  # Latest row wins; on an epoch tie the later line wins (same-second re-run).
  local latest ec sub cmd
  latest=$(printf '%s\n' "${rows}" | awk -F'\t' '{ if ($3+0 >= m+0) { m=$3; L=$0 } } END { print L }')
  ec=$(printf '%s' "${latest}" | cut -f2)
  sub=$(printf '%s' "${latest}" | cut -f4)
  cmd=$(printf '%s' "${latest}" | cut -f5)

  if [[ "${ec}" != "0" ]]; then
    printf 'the last verification run this turn FAILED: `%s`\n' "${cmd}"
    return 1
  fi
  # Only an explicit zero-test statement counts against a green run. Silence is
  # success for tsc/eslint and friends — see the substance classifier.
  if [[ "${sub}" == "none" ]]; then
    printf 'the verification run `%s` exited 0 but reported that it ran no tests\n' "${cmd}"
    return 3
  fi
  return 0
}

# orch_evidence_unbacked_claim <reply> <session_id> <since_epoch> <verify_re>
# Prints a reason and returns 1 when the reply's Verify: block NAMES a
# verify-shaped command that the ledger has no green record of this turn.
#
# This is the check that lets the gate say "you have no evidence" rather than
# only "your evidence is wrong". Without it the mechanism was fail-open by
# construction: an entirely invented Verify: block — a plausible pytest summary
# for a run that never happened — passed silently, warn AND strict, because an
# empty window was treated as "nothing to say". That is precisely the
# fabrication path (MAST FM-2.6) the ledger exists to close.
#
# Scoped deliberately: it fires only when the reply names a command the harness
# WOULD have recorded. A project verifying with a custom script the regex does
# not know stays silent, because there we genuinely know nothing.
orch_evidence_unbacked_claim() {
  local reply="$1" sid="$2" since="$3" vre="$4" dir ledger section named row
  local backed=0 unbacked="" first_unbacked=""
  [[ -n "${since}" && -n "${vre}" ]] || return 0
  dir=$(orch_evidence_state_dir)
  ledger="${dir}/evidence.${sid}.tsv"

  # --- the Verify: section ------------------------------------------------
  # Header forms must match what orch_has_section accepts. Requiring a bare
  # `Verify:` meant `**Verify:**` and `- Verify:` extracted nothing at all, so a
  # fabricated claim in the better-formatted reply was invisible here.
  section=$(printf '%s\n' "${reply}" | awk '
    /^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}Verify[*_]{0,2}:/ {
      insec = 1
      sub(/^[[:space:]]*([-*][[:space:]]*)?(#{1,6}[[:space:]]*)?[*_]{0,2}Verify[*_]{0,2}:[*_]{0,2}/, "")
      print; next }
    insec && /^[[:space:]]*(Changed|Found|Blocked|Issues|Plan|Status|Why|Next|Notes|Risks|Summary|Concerns|Need|Ask|Progress|Remaining):/ { insec = 0 }
    insec { print }')
  [[ -n "${section}" ]] || return 0

  # --- candidate claims ---------------------------------------------------
  # Normalize the ways a human pastes a command before matching: backticks, a
  # `$ ` or `> ` prompt, a bullet, an arrow, a checkmark. `$ pytest -q` is the
  # single most common form and extracted nothing.
  #
  # Lines that DISCLAIM a run are dropped. Scanning them punished honesty: a
  # reply saying "`npm test` not run — no node toolchain here" was blocked, and
  # the model's cheapest fix would have been to delete the honest sentence.
  named=$(printf '%s\n' "${section}" \
    | grep -viE '\b(not run|never run|did ?n.?t run|was ?n.?t run|not executed|not needed|skipped|unaffected|n/a|instead of|rather than|no longer)\b' \
    | tr '`' '\n' \
    | sed -E 's/^[[:space:]]*([-*+•]|[0-9]+[.)])[[:space:]]*//; s/^[[:space:]]*[$>][[:space:]]+//; s/^[[:space:]]*(→|->|=>|✓|✔|»)[[:space:]]*//; s/^[[:space:]]*(i[[:space:]]+)?(re-?)?(ran|run|executed|running)[[:space:]]+(the[[:space:]]+)?//' \
    | grep -oE "${vre}.*" 2>/dev/null \
    | sed -E 's/[[:space:]]*(→|->|=>|—|\|\||#).*$//; s/[[:space:]]{2,}.*$//; s/^[[:space:]]*[;&|]?[[:space:]]*//; s/[[:space:]]+$//' \
    | grep -vE '^[[:space:]]*$' | sort -u)
  [[ -n "${named}" ]] || return 0

  # --- corroborate --------------------------------------------------------
  # Warn only when NOTHING named in the section is backed. A Verify: block
  # legitimately mentions more commands than it ran: `make test` echoes its
  # recipe (`pytest -q`) into the pasted output, and an honest reply names a
  # suite it deliberately skipped. Requiring EVERY name to be backed blocked
  # exactly those two, which are the replies that did the most work.
  while IFS= read -r cmdtext; do
    [[ -n "${cmdtext}" ]] || continue
    row=""
    [[ -f "${ledger}" ]] && row=$(awk -F'\t' -v s="${since}" -v c="${cmdtext}" \
      '$3+0 >= s+0 && $2 == "0" && index($5, c) > 0 { print; exit }' "${ledger}" 2>/dev/null)
    if [[ -n "${row}" ]]; then
      backed=1
    else
      [[ -n "${first_unbacked}" ]] || first_unbacked="${cmdtext}"
      unbacked="${unbacked}${cmdtext}
"
    fi
  done <<< "${named}"

  if [[ ${backed} -eq 0 && -n "${first_unbacked}" ]]; then
    printf 'the Verify: block claims `%s`, but no command it names was recorded running green this turn\n' "${first_unbacked}"
    return 1
  fi
  return 0
}

# orch_evidence_red_first <session_id> <since_epoch>
# Reports whether the test suite was ever seen FAILING this turn before it was
# seen passing.
#
# "If you didn't watch the test fail, you don't know if it tests the right
# thing." That principle is stated in every TDD guide and enforced by none of
# them, because checking it needs a record of what ran — which this ledger
# already keeps and nothing was reading as a sequence.
#
# A test written after the code passes on its first run. So does a test that
# asserts nothing, a test that never executes, and a test that mirrors the
# implementation back at itself. All four are invisible to a green suite; all
# four are visible here, because none of them ever produced a red row.
#
# Return codes:
#   0 — a red row precedes a green row for the same command (the cycle is real)
#   1 — green rows exist, none preceded by a red for that command
#   2 — nothing to judge (no rows in the window, or window unknown)
orch_evidence_red_first() {
  local sid="$1" since="$2" dir ledger rows verdict
  [[ -n "${since}" ]] || return 2
  dir=$(orch_evidence_state_dir)
  ledger="${dir}/evidence.${sid}.tsv"
  [[ -f "${ledger}" ]] || return 2

  rows=$(awk -F'\t' -v s="${since}" '$3+0 >= s+0' "${ledger}" 2>/dev/null)
  [[ -n "${rows}" ]] || return 2

  # For each command, did a red row appear at or before its first green row?
  verdict=$(printf '%s\n' "${rows}" | awk -F'\t' '
    { c = $5; ep = $3 + 0
      if ($2 != "0") { if (!(c in red) || ep < red[c]) red[c] = ep }
      else           { if (!(c in grn) || ep < grn[c]) grn[c] = ep } }
    END {
      any_green = 0; watched = 0
      for (c in grn) {
        any_green = 1
        if (c in red && red[c] <= grn[c]) watched = 1
      }
      if (!any_green)      print "none"
      else if (watched)    print "watched"
      else                 print "unwatched" }')

  case "${verdict}" in
    watched)   return 0 ;;
    unwatched) printf 'the suite went green this turn without ever being seen red\n'; return 1 ;;
    *)         return 2 ;;
  esac
}

# orch_touches_tests <name-list>
# True when any path in <name-list> looks like a test file. Used to scope the
# red-phase note: a docs or config change has no red phase to skip.
orch_touches_tests() {
  # Test-ness lives in the FILENAME. A bare `spec/` or `tests/` directory rule
  # matched this plugin's own `docs/llm-orchestrator/specs/*.md`, `api/spec/
  # openapi.yaml` and `test/README.md` — so writing a spec and running the suite
  # green once fired the red-phase note. rspec's `user_spec.rb` and pytest's
  # `test_x.py` are caught by their suffixes, which is where the signal actually is.
  printf '%s\n' "$1" \
    | grep -E '\.(py|rb|js|jsx|ts|tsx|mjs|cjs|go|rs|java|kt|swift|cs|php|ex|exs|sh|bats)$' \
    | grep -qE '[._-](test|spec)\.[A-Za-z0-9]+$|_test\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.[A-Za-z0-9]+$|(^|/)(tests?|__tests__)/[^/]*$|Tests?\.(java|kt|cs|swift)$'
}

# orch_evidence_stamp_of <text>
# Prints the first stamp hash cited in <text> ("[orch-evidence <hex> ...]"),
# or nothing. Only meaningful under ORCH_EVIDENCE_MARKER=1.
orch_evidence_stamp_of() {
  printf '%s' "$1" | grep -oE '\[orch-evidence [0-9a-f]{8,40}' | head -1 | awk '{print $2}'
}

# orch_evidence_check <reply_text> <ledger_path>
# Validates any evidence stamps CITED in a reply against the ledger. This is the
# secondary path: it fires only when a stamp is present, so it cannot nag a
# reply that (correctly, under the default config) cites nothing.
# Return codes:
#   0 — no stamp cited, or every cited stamp is recorded green
#   1 — HARD: a cited stamp is absent from the ledger (fabricated), or is
#       recorded with a non-zero exit (the cited run actually FAILED)
orch_evidence_check() {
  local reply="$1" ledger="$2" stamp line ec all
  [[ -f "${ledger}" ]] || return 0

  all=$(printf '%s' "${reply}" | grep -oE '\[orch-evidence [0-9a-f]{8,40}' | awk '{print $2}' | sort -u)
  [[ -n "${all}" ]] || return 0

  while IFS= read -r stamp; do
    [[ -n "${stamp}" ]] || continue
    line=$(grep -m1 "^${stamp}	" "${ledger}" 2>/dev/null || true)
    if [[ -z "${line}" ]]; then
      printf 'stamp %s is not in the evidence ledger — no such verification run was recorded (fabricated or copied from another session)\n' "${stamp}"
      return 1
    fi
    ec=$(printf '%s' "${line}" | cut -f2)
    if [[ "${ec}" != "0" ]]; then
      printf 'stamp %s is recorded with exit=%s — the cited verification run FAILED\n' "${stamp}" "${ec}"
      return 1
    fi
  done <<< "${all}"
  return 0
}
