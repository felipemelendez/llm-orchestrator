#!/usr/bin/env bash
# Run every test suite in this repo.
#
# This exists because CI listed its suites by hand, and the list drifted: ten
# suites — including the writer-mutex modes, the retry cap, the telemetry
# contract, and all three handoff suites — were never run by CI at all, while CI
# reported green. An enumeration that must be edited whenever a file is added is
# a guard applied to one path and not its siblings, which is the defect class
# this repo keeps finding. So the suite list is now discovered, not typed.
#
# Any suite deliberately left out must be named in SKIP below with a reason, and
# it is printed on every run — a silent exclusion reads as coverage it isn't.
#
#   bash tests/run-all.sh                 # everything
#   ORCH_REQUIRE_DEPS=1 bash tests/run-all.sh   # missing dependency is a failure, not a skip
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# name<TAB>reason. tests/evals/run-evals.sh is not matched by the globs below and
# needs no entry: it makes paid API calls and is never part of an unattended run.
SKIP="$(cat <<'EOF'
tests/run-all.sh	this runner
EOF
)"

GREEN=''; RED=''; DIM=''; RESET=''
if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'; fi

skipped_note() { printf '%s' "$SKIP" | while IFS=$'\t' read -r f r; do
  [[ -n "$f" ]] && printf '  %sskip %-38s %s%s\n' "$DIM" "$f" "$r" "$RESET"
done; }

is_skipped() { printf '%s' "$SKIP" | cut -f1 | command grep -qxF "$1"; }

suites=()
for t in tests/*.sh tests/handoff/*.sh; do
  [[ -f "$t" ]] || continue
  is_skipped "$t" && continue
  suites+=("$t")
done

# Discovering nothing must not print PASS. A glob that stops matching — a moved
# directory, a run from the wrong root — would otherwise report a clean sweep of
# zero suites, which is the loudest possible way to be silently broken.
if [[ ${#suites[@]} -eq 0 ]]; then
  printf '%sFAIL%s no test suites discovered under %s/tests — refusing to report success\n' \
    "$RED" "$RESET" "$ROOT"
  exit 1
fi

echo "== ${#suites[@]} test suites =="
skipped_note

failed=()
for t in "${suites[@]}"; do
  start=$(date +%s)
  out="$(bash "$t" 2>&1)"; rc=$?
  dur=$(( $(date +%s) - start ))
  if [[ $rc -eq 0 ]]; then
    printf '  %sok%s   %-38s %ss\n' "$GREEN" "$RESET" "$t" "$dur"
  else
    printf '  %sFAIL%s %-38s %ss (exit %s)\n' "$RED" "$RESET" "$t" "$dur" "$rc"
    printf '%s\n' "$out" | tail -25 | sed 's/^/       /'
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
