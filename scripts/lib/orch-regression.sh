#!/usr/bin/env bash
# LLM Orchestrator — regression guard.
#
# Captures a green baseline when a worktree is created and refuses to finish a
# branch if a previously-green suite now fails.
#
# Public API:
#   orch_regression_baseline <dir>  — run the detected test suite, record pass/fail
#   orch_regression_check <dir>     — re-run, compare to baseline; nonzero on regression
#
# Sourced via orch-detect.sh, which defines the toolchain-detection and cache
# helpers these functions rely on (orch_detect_toolchain, _orch_proj_cache_dir).
# Bash 3.2 compatible. Never performs a destructive action.

if ! declare -f orch_regression_baseline >/dev/null 2>&1; then

# ---------------------------------------------------------------------------
# orch_regression_baseline <dir>
#
# Detects the test command for <dir>, runs it, then records the outcome into
#   ${ORCH_HOME:-~/.llm-orchestrator}/toolchain/<hash>/baseline.md
#
# The baseline file contains:
#   status: pass | fail
#   test-cmd: <command>
#   output: <first 40 lines of test output>
#
# Returns 0 when the test command itself exits 0 (green baseline).
# Returns nonzero if detection finds no test command or the command fails.
# ---------------------------------------------------------------------------
orch_regression_baseline() {
  local dir="${1:-.}"
  dir="${dir%/}"

  # Detect test command.
  local test_cmd
  test_cmd=$(orch_detect_toolchain "$dir" 2>/dev/null | grep '^test=' | head -1 | cut -d= -f2-)

  if [[ -z "$test_cmd" ]]; then
    printf 'regression-baseline: no test command detected in %s\n' "$dir" >&2
    return 1
  fi

  # Run the test command from <dir>.
  local output exit_code
  output=$(cd "$dir" && eval "$test_cmd" 2>&1)
  exit_code=$?

  local status="fail"
  [[ $exit_code -eq 0 ]] && status="pass"

  # Write baseline to cache.
  local cache_dir
  cache_dir=$(_orch_proj_cache_dir "$dir")
  mkdir -p "$cache_dir"

  local baseline_file="${cache_dir}/baseline.md"
  {
    printf 'status: %s\n' "$status"
    printf 'test-cmd: %s\n' "$test_cmd"
    printf 'exit-code: %d\n' "$exit_code"
    printf '\n## output\n'
    printf '%s\n' "$output" | head -40
  } > "$baseline_file"

  return $exit_code
}

# ---------------------------------------------------------------------------
# orch_regression_check <dir>
#
# Re-detects the test command for <dir>, runs it, and compares against the
# recorded baseline (written by orch_regression_baseline).
#
# Returns 0  — suite passes now (or baseline was not green, so no guard).
# Returns 1  — baseline was green but suite is now failing (regression).
# Returns 2  — no baseline file found; run orch_regression_baseline first.
#
# On regression, prints a human-readable summary of what regressed.
# Never performs any destructive action.
# ---------------------------------------------------------------------------
orch_regression_check() {
  local dir="${1:-.}"
  dir="${dir%/}"

  local cache_dir
  cache_dir=$(_orch_proj_cache_dir "$dir")
  local baseline_file="${cache_dir}/baseline.md"

  if [[ ! -f "$baseline_file" ]]; then
    printf 'regression-check: no baseline found for %s — run orch_regression_baseline first\n' "$dir" >&2
    return 2
  fi

  # Read baseline status.
  local baseline_status
  baseline_status=$(grep '^status:' "$baseline_file" | head -1 | awk '{print $2}')

  # If baseline was not green, no regression guard applies.
  if [[ "$baseline_status" != "pass" ]]; then
    printf 'regression-check: baseline was not green (status: %s); skipping guard\n' "$baseline_status" >&2
    return 0
  fi

  # Detect and run test command now.
  local test_cmd
  test_cmd=$(orch_detect_toolchain "$dir" 2>/dev/null | grep '^test=' | head -1 | cut -d= -f2-)

  if [[ -z "$test_cmd" ]]; then
    printf 'regression-check: no test command detected in %s\n' "$dir" >&2
    return 0
  fi

  local current_output current_exit
  current_output=$(cd "$dir" && eval "$test_cmd" 2>&1)
  current_exit=$?

  if [[ $current_exit -ne 0 ]]; then
    printf 'REGRESSION DETECTED in %s\n' "$dir"
    printf '  baseline: pass\n'
    printf '  current:  fail (exit %d)\n' "$current_exit"
    printf '  test-cmd: %s\n' "$test_cmd"
    printf '  output:\n'
    printf '%s\n' "$current_output" | head -20 | sed 's/^/    /'
    return 1
  fi

  return 0
}

fi  # end double-source guard
