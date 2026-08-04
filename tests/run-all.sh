#!/usr/bin/env bash
# Run every test suite in this repo.
#
# This exists because CI listed its suites by hand, and the list drifted: eight
# suites — the writer-mutex modes, the retry cap, the telemetry contract,
# detect, hook latency, and all three handoff suites — were never run by CI at
# all, while CI reported green. An enumeration that must be edited whenever a
# file is added is a guard applied to one path and not its siblings, which is
# the defect class this repo keeps finding. So the suite list is now
# DISCOVERED, RECURSIVELY: every *.sh under tests/ is a candidate, however
# deep. (The first version of this file used two literal globs — tests/*.sh
# and tests/handoff/*.sh — which re-created the same drift one level up: a
# suite in any NEW subdirectory was silently not run.)
#
# Every candidate is either run or matches a SKIP entry below, printed on every
# run — a silent exclusion reads as coverage it isn't. Entries ending in `/`
# skip a whole directory.
#
# Each suite runs under a per-suite timeout (no timeout(1) on stock macOS, so
# it is a background job with a bounded poll), and the suite's name is printed
# BEFORE it runs: a suite that hangs is attributable from the log even when
# the whole runner is killed from outside.
#
#   bash tests/run-all.sh                       # everything
#   ORCH_REQUIRE_DEPS=1 bash tests/run-all.sh   # missing dependency is a failure, not a skip
#   ORCH_SUITE_TIMEOUT=60 bash tests/run-all.sh # per-suite cap in seconds (default 600)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SUITE_TIMEOUT="${ORCH_SUITE_TIMEOUT:-600}"

# name<TAB>reason. A trailing / skips the directory's whole subtree.
SKIP="$(cat <<'EOF'
tests/run-all.sh	this runner
tests/evals/	makes paid API calls — run tests/evals/run-evals.sh by hand, never unattended
tests/lib/	helper library sourced by suites, not suites
EOF
)"

GREEN=''; RED=''; DIM=''; RESET=''
if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'; fi

skipped_note() { printf '%s' "$SKIP" | while IFS=$'\t' read -r f r; do
  [[ -n "$f" ]] && printf '  %sskip %-38s %s%s\n' "$DIM" "$f" "$r" "$RESET"
done; }

is_skipped() { # <relative path>
  local f="$1" e r
  while IFS=$'\t' read -r e r; do
    [[ -z "$e" ]] && continue
    if [[ "$e" == */ ]]; then
      [[ "$f" == "$e"* ]] && return 0
    else
      [[ "$f" == "$e" ]] && return 0
    fi
  done <<EOF
$SKIP
EOF
  return 1
}

suites=()
while IFS= read -r t; do
  [[ -f "$t" ]] || continue
  is_skipped "$t" && continue
  suites+=("$t")
done < <(find tests -name '*.sh' -type f | sort)

# Discovering nothing must not print PASS. A find that stops matching — a moved
# directory, a run from the wrong root — would otherwise report a clean sweep of
# zero suites, which is the loudest possible way to be silently broken.
if [[ ${#suites[@]} -eq 0 ]]; then
  printf '%sFAIL%s no test suites discovered under %s/tests — refusing to report success\n' \
    "$RED" "$RESET" "$ROOT"
  exit 1
fi

echo "== ${#suites[@]} test suites =="
skipped_note

# run_suite <suite> <output-file>: 0 = pass, 1 = fail, sets TIMED_OUT=1 on cap.
# stdin is /dev/null so a suite that reads it fails fast instead of hanging.
TIMED_OUT=0
run_suite() {
  local t="$1" outf="$2" pid waited limit rc
  TIMED_OUT=0
  bash "$t" > "$outf" 2>&1 < /dev/null &
  pid=$!
  waited=0
  limit=$((SUITE_TIMEOUT * 5))   # 0.2s poll ticks
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      TIMED_OUT=1
      kill "$pid" 2>/dev/null
      sleep 1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

RUNTMP=$(mktemp -d)
trap 'rm -rf "$RUNTMP"' EXIT

failed=()
for t in "${suites[@]}"; do
  # Named BEFORE it runs: if this suite hangs and the runner is killed from
  # outside (CI job timeout), the last "run" line names the culprit.
  printf '  %srun%s  %s\n' "$DIM" "$RESET" "$t"
  start=$(date +%s)
  # run_suite writes suite output to the file and nothing of its own to
  # stderr; the redirect only mutes bash's async "Terminated" job notice
  # when a timed-out suite is killed.
  rc=0; run_suite "$t" "$RUNTMP/out" 2>/dev/null || rc=$?
  dur=$(( $(date +%s) - start ))
  if (( TIMED_OUT )); then
    printf '  %sTIMEOUT%s %-34s exceeded %ss — killed\n' "$RED" "$RESET" "$t" "$SUITE_TIMEOUT"
    tail -25 "$RUNTMP/out" | sed 's/^/       /'
    failed+=("$t")
  elif [[ $rc -eq 0 ]]; then
    printf '  %sok%s   %-38s %ss\n' "$GREEN" "$RESET" "$t" "$dur"
  else
    printf '  %sFAIL%s %-38s %ss (exit %s)\n' "$RED" "$RESET" "$t" "$dur" "$rc"
    tail -25 "$RUNTMP/out" | sed 's/^/       /'
    failed+=("$t")
  fi
done

echo
if [[ ${#failed[@]} -eq 0 ]]; then
  printf '%sPASS%s all %s suites\n' "$GREEN" "$RESET" "${#suites[@]}"
else
  printf '%sFAIL%s %s of %s suites: %s\n' "$RED" "$RESET" "${#failed[@]}" "${#suites[@]}" "${failed[*]}"
  exit 1
fi
