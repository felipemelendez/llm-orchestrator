#!/usr/bin/env bash
# LLM Orchestrator — toolchain + convention detection library.
#
# Detects a project's real commands and conventions from manifest files and
# caches the result per-project keyed by the sha1 of manifest content.
# Re-detects only when the manifest content changes.
#
# Public API:
#   orch_detect_toolchain <dir>   — print key=command lines for test/lint/typecheck/build
#   orch_detect_conventions <dir> — print short conventions block
#   orch_detect_cached <dir>      — return cached detection, re-detecting on manifest change
#
# SAFETY: never runs any detected command. Read-only filesystem access only.
# Never emits deploy/publish/release/destructive keys.
#
# Bash 3.2 compatible.

# Resolve paths relative to this file. Use ${BASH_SOURCE[0]:-$0} so self-location
# works when this lib is sourced under zsh too (zsh leaves BASH_SOURCE unset but
# sets $0 to the sourced file). Without this, sibling sources below resolve
# against the caller's cwd and fail when sourced from another directory.
_DETECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source sibling libraries if not already loaded.
if ! declare -f orch_project_hash >/dev/null 2>&1; then
  # shellcheck source=orch-project.sh
  source "${_DETECT_LIB_DIR}/orch-project.sh"
fi
if ! declare -f with_lock >/dev/null 2>&1; then
  # shellcheck source=orch-lock.sh
  source "${_DETECT_LIB_DIR}/orch-lock.sh"
fi

# ---------------------------------------------------------------------------
# Internal: jq-or-grep JSON value extractor.
# Usage: _orch_json_script_val <file> <script-name>
# Prints the value of .scripts.<script-name> or empty string.
# ---------------------------------------------------------------------------
_orch_json_script_val() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.scripts[$k] // empty' "$file" 2>/dev/null
  else
    # Grep-based fallback: look for "key": "value" pattern.
    # Handles both compact and pretty-printed JSON.
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
      | head -1 \
      | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/'
  fi
}

# ---------------------------------------------------------------------------
# Internal: check if a toml file contains a given tool section or key.
# Usage: _orch_toml_has <file> <pattern>
# Returns 0 if pattern found.
# ---------------------------------------------------------------------------
_orch_toml_has() {
  grep -qE "$2" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Internal: check if a Makefile has a given target.
# Usage: _orch_make_has_target <file> <target>
# ---------------------------------------------------------------------------
_orch_make_has_target() {
  grep -qE "^${2}[[:space:]]*:" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# orch_detect_toolchain <dir>
#
# Reads manifest files in <dir> and emits "key=command" lines for the
# following safe command categories: test, lint, typecheck, build.
# Never emits deploy, publish, release, or any other destructive key.
#
# Precedence (first matching manifest wins per command kind):
#   1. package.json (Node)
#   2. pyproject.toml (Python)
#   3. Cargo.toml (Rust)
#   4. go.mod (Go)
#   5. Makefile (fallback for any language)
# ---------------------------------------------------------------------------
orch_detect_toolchain() {
  local dir="${1:-.}"
  dir="${dir%/}"   # strip trailing slash

  local pkg_json="${dir}/package.json"
  local pyproject="${dir}/pyproject.toml"
  local cargo="${dir}/Cargo.toml"
  local gomod="${dir}/go.mod"
  local makefile="${dir}/Makefile"

  # We collect each key independently so manifests can supply different keys.
  # But package.json wins for all keys it covers (first-match-per-key logic).

  local test_cmd="" lint_cmd="" typecheck_cmd="" build_cmd=""

  # ---- 1. package.json ----
  if [[ -f "$pkg_json" ]]; then
    local val
    val=$(_orch_json_script_val "$pkg_json" "test")
    [[ -n "$val" ]] && test_cmd="npm run test"

    val=$(_orch_json_script_val "$pkg_json" "lint")
    [[ -n "$val" ]] && lint_cmd="npm run lint"

    val=$(_orch_json_script_val "$pkg_json" "typecheck")
    [[ -n "$val" ]] && typecheck_cmd="npm run typecheck"

    val=$(_orch_json_script_val "$pkg_json" "build")
    [[ -n "$val" ]] && build_cmd="npm run build"
  fi

  # ---- 2. pyproject.toml ----
  if [[ -f "$pyproject" ]]; then
    # test: pytest present if [tool.pytest.ini_options] or pytest in deps
    if [[ -z "$test_cmd" ]] && _orch_toml_has "$pyproject" 'tool\.pytest|pytest'; then
      test_cmd="pytest"
    fi
    # lint: ruff
    if [[ -z "$lint_cmd" ]] && _orch_toml_has "$pyproject" 'tool\.ruff|ruff'; then
      lint_cmd="ruff check"
    fi
    # typecheck: mypy
    if [[ -z "$typecheck_cmd" ]] && _orch_toml_has "$pyproject" 'tool\.mypy|mypy'; then
      typecheck_cmd="mypy"
    fi
  fi

  # ---- 3. Cargo.toml ----
  if [[ -f "$cargo" ]]; then
    [[ -z "$test_cmd" ]] && test_cmd="cargo test"
    [[ -z "$lint_cmd" ]] && lint_cmd="cargo clippy"
    # build: cargo build (only if not set)
    [[ -z "$build_cmd" ]] && build_cmd="cargo build"
  fi

  # ---- 4. go.mod ----
  if [[ -f "$gomod" ]]; then
    [[ -z "$test_cmd" ]] && test_cmd="go test ./..."
    [[ -z "$lint_cmd" ]] && lint_cmd="go vet ./..."
    [[ -z "$build_cmd" ]] && build_cmd="go build ./..."
  fi

  # ---- 5. Makefile ----
  if [[ -f "$makefile" ]]; then
    if [[ -z "$test_cmd" ]] && _orch_make_has_target "$makefile" "test"; then
      test_cmd="make test"
    fi
    if [[ -z "$lint_cmd" ]] && _orch_make_has_target "$makefile" "lint"; then
      lint_cmd="make lint"
    fi
    if [[ -z "$build_cmd" ]] && _orch_make_has_target "$makefile" "build"; then
      build_cmd="make build"
    fi
  fi

  # Emit only non-empty keys.
  [[ -n "$test_cmd"      ]] && printf 'test=%s\n'      "$test_cmd"
  [[ -n "$lint_cmd"      ]] && printf 'lint=%s\n'      "$lint_cmd"
  [[ -n "$typecheck_cmd" ]] && printf 'typecheck=%s\n' "$typecheck_cmd"
  [[ -n "$build_cmd"     ]] && printf 'build=%s\n'     "$build_cmd"
}

# ---------------------------------------------------------------------------
# orch_detect_conventions <dir>
#
# Prints a short human-readable block describing detected conventions:
# test runner, linter, formatter, type checker, indentation hints.
# Output is informational; not machine-parsed.
# ---------------------------------------------------------------------------
orch_detect_conventions() {
  local dir="${1:-.}"
  dir="${dir%/}"

  local pkg_json="${dir}/package.json"
  local pyproject="${dir}/pyproject.toml"
  local cargo="${dir}/Cargo.toml"
  local gomod="${dir}/go.mod"

  local runner="" linter="" formatter="" typechecker="" lang=""

  # Language detection
  if [[ -f "$pkg_json" ]]; then
    lang="node"
    local val
    val=$(_orch_json_script_val "$pkg_json" "test")
    case "$val" in
      *jest*)    runner="jest" ;;
      *vitest*)  runner="vitest" ;;
      *mocha*)   runner="mocha" ;;
      *tap*)     runner="tap" ;;
      *node*)    runner="node" ;;
      *)         [[ -n "$val" ]] && runner="npm run test" ;;
    esac

    val=$(_orch_json_script_val "$pkg_json" "lint")
    case "$val" in
      *eslint*)  linter="eslint" ;;
      *biome*)   linter="biome" ;;
      *tslint*)  linter="tslint" ;;
      *oxlint*)  linter="oxlint" ;;
    esac

    # Formatter detection
    if [[ -f "${dir}/.prettierrc" || -f "${dir}/.prettierrc.js" || \
          -f "${dir}/.prettierrc.json" || -f "${dir}/.prettierrc.yaml" || \
          -f "${dir}/.prettierrc.yml" ]]; then
      formatter="prettier"
    elif [[ -n "$linter" ]] && [[ "$linter" == "biome" ]]; then
      formatter="biome"
    fi

    # Typecheck
    val=$(_orch_json_script_val "$pkg_json" "typecheck")
    [[ -n "$val" ]] && typechecker="typescript (tsc)"
  fi

  if [[ -f "$pyproject" ]]; then
    lang="python"
    _orch_toml_has "$pyproject" 'tool\.pytest|pytest' && runner="pytest"
    _orch_toml_has "$pyproject" 'tool\.ruff|ruff'     && linter="ruff"
    _orch_toml_has "$pyproject" 'tool\.mypy|mypy'     && typechecker="mypy"
    if [[ -f "${dir}/ruff.toml" ]]; then formatter="ruff format"; fi
  fi

  if [[ -f "$cargo" ]]; then
    lang="rust"
    runner="cargo test"
    linter="cargo clippy"
    if [[ -f "${dir}/.rustfmt.toml" || -f "${dir}/rustfmt.toml" ]]; then
      formatter="rustfmt"
    else
      formatter="rustfmt (default)"
    fi
  fi

  if [[ -f "$gomod" ]]; then
    lang="go"
    runner="go test ./..."
    linter="go vet"
    formatter="gofmt (standard)"
  fi

  # Shared: .editorconfig
  local indent_hint=""
  if [[ -f "${dir}/.editorconfig" ]]; then
    local indent_style indent_size
    indent_style=$(grep -E '^indent_style' "${dir}/.editorconfig" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
    indent_size=$(grep -E '^indent_size' "${dir}/.editorconfig" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
    if [[ -n "$indent_style" ]]; then
      indent_hint="${indent_style}"
      [[ -n "$indent_size" ]] && indent_hint="${indent_hint} ${indent_size}"
    fi
  fi

  # Emit
  if [[ -z "$lang" && -z "$runner" ]]; then
    return 0
  fi

  [[ -n "$lang"        ]] && printf 'language: %s\n'    "$lang"
  [[ -n "$runner"      ]] && printf 'test-runner: %s\n' "$runner"
  [[ -n "$linter"      ]] && printf 'linter: %s\n'      "$linter"
  [[ -n "$typechecker" ]] && printf 'typecheck: %s\n'   "$typechecker"
  [[ -n "$formatter"   ]] && printf 'formatter: %s\n'   "$formatter"
  [[ -n "$indent_hint" ]] && printf 'indent: %s\n'      "$indent_hint"
  return 0
}

# ---------------------------------------------------------------------------
# Internal: compute a sha1 fingerprint of all manifest files present in <dir>.
# The fingerprint covers content only (not mtime), so touching a file without
# changing its content does not invalidate the cache.
# ---------------------------------------------------------------------------
_orch_manifest_sha() {
  local dir="$1"
  local combined=""
  local f

  for f in \
    "${dir}/package.json" \
    "${dir}/pyproject.toml" \
    "${dir}/Cargo.toml" \
    "${dir}/go.mod" \
    "${dir}/Makefile"; do
    if [[ -f "$f" ]]; then
      # Prefix each file's content with its path + newline so that two different
      # manifest sets whose content happens to concatenate identically still hash
      # differently (prevents collision when one file's tail merges into the next).
      combined="${combined}
${f}
$(cat "$f" 2>/dev/null)"
    fi
  done

  orch_sha1_of "$combined"
}

# ---------------------------------------------------------------------------
# Internal: _orch_detect_write_cache <dir> <cache_file>
# Runs detection and writes result to <cache_file> (assumed locked by caller).
# ---------------------------------------------------------------------------
_orch_detect_write_cache() {
  local dir="$1"
  local cache_file="$2"
  local manifest_sha
  manifest_sha=$(_orch_manifest_sha "$dir")

  local toolchain_out
  toolchain_out=$(orch_detect_toolchain "$dir" 2>/dev/null)
  local conventions_out
  conventions_out=$(orch_detect_conventions "$dir" 2>/dev/null)

  {
    printf 'manifest-sha: %s\n' "$manifest_sha"
    printf '\n## Toolchain\n'
    if [[ -n "$toolchain_out" ]]; then
      printf '%s\n' "$toolchain_out"
    else
      printf '(none detected)\n'
    fi
    printf '\n## Conventions\n'
    if [[ -n "$conventions_out" ]]; then
      printf '%s\n' "$conventions_out"
    else
      printf '(none detected)\n'
    fi
  } > "$cache_file"
}

# ---------------------------------------------------------------------------
# Internal: _orch_proj_cache_dir <dir>
# Prints the per-project cache directory path (creating nothing).
# ---------------------------------------------------------------------------
_orch_proj_cache_dir() {
  local dir="$1"
  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi
  printf '%s/toolchain/%s' "$home_dir" "$proj_hash"
}

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

# ---------------------------------------------------------------------------
# orch_arch_record <dir> <decisions-text>
#
# Writes the studied architectural decisions to:
#   ${ORCH_HOME:-~/.llm-orchestrator}/architecture/<project-hash>/decisions.md
#
# The file is written under with_lock and stamped with a manifest-sha: line
# (from _orch_manifest_sha "<dir>") so orch_arch_cached can detect staleness.
# ---------------------------------------------------------------------------
orch_arch_record() {
  local dir="${1:-.}"
  dir="${dir%/}"
  local decisions="${2:-}"

  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi

  local arch_dir="${home_dir}/architecture/${proj_hash}"
  mkdir -p "$arch_dir"

  local decisions_file="${arch_dir}/decisions.md"
  local manifest_sha
  manifest_sha=$(_orch_manifest_sha "$dir")

  _orch_arch_write() {
    local d_file="$1" m_sha="$2" d_text="$3"
    {
      printf 'manifest-sha: %s\n\n' "$m_sha"
      printf '%s\n' "$d_text"
    } > "$d_file"
  }

  local lock_rc=0
  with_lock "$decisions_file" _orch_arch_write "$decisions_file" "$manifest_sha" "$decisions" || lock_rc=$?
  if [[ $lock_rc -ne 0 ]]; then
    _orch_arch_write "$decisions_file" "$manifest_sha" "$decisions"
  fi
}

# ---------------------------------------------------------------------------
# orch_arch_cached <dir>
#
# Returns cached architectural decisions for <dir> if they exist and the stored
# manifest-sha matches the current one (cache hit).
#
# Exit 0 + prints decisions  — cache hit (study still valid).
# Exit 1                      — cache miss or stale (study needed).
#
# Mirrors the read/staleness logic of orch_detect_cached.
# ---------------------------------------------------------------------------
orch_arch_cached() {
  local dir="${1:-.}"
  dir="${dir%/}"

  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi

  local decisions_file="${home_dir}/architecture/${proj_hash}/decisions.md"

  if [[ ! -f "$decisions_file" ]]; then
    return 1
  fi

  local current_sha stored_sha
  current_sha=$(_orch_manifest_sha "$dir")
  stored_sha=$(grep -E '^manifest-sha:' "$decisions_file" 2>/dev/null | head -1 | awk '{print $2}')

  if [[ "$stored_sha" != "$current_sha" ]]; then
    return 1
  fi

  # Cache hit — print decisions (skip manifest-sha header line).
  grep -v '^manifest-sha:' "$decisions_file"
  return 0
}

# ---------------------------------------------------------------------------
# orch_detect_cached <dir>
#
# Returns cached detection for <dir>. Cache lives at:
#   ${ORCH_HOME:-~/.llm-orchestrator}/toolchain/<project-hash>/config.md
#
# The first line of the cache file is "manifest-sha: <sha>". On each call the
# sha of the current manifest files is recomputed; if it matches the stored
# sha, the cached content is returned as-is. If it differs (or the cache is
# absent), detection runs again under with_lock and the cache is rewritten.
# ---------------------------------------------------------------------------
orch_detect_cached() {
  local dir="${1:-.}"
  dir="${dir%/}"

  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash

  # Compute hash from <dir> as the working context.
  # We temporarily push the dir so orch_project_hash sees git info from there.
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""

  # Fallback: hash the dir path itself if no git context.
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi

  local cache_dir="${home_dir}/toolchain/${proj_hash}"
  local cache_file="${cache_dir}/config.md"

  # Compute current manifest sha.
  local current_sha
  current_sha=$(_orch_manifest_sha "$dir")

  # Check cached sha.
  if [[ -f "$cache_file" ]]; then
    local stored_sha
    stored_sha=$(grep -E '^manifest-sha:' "$cache_file" 2>/dev/null | head -1 | awk '{print $2}')
    if [[ "$stored_sha" == "$current_sha" ]]; then
      # Cache hit — return stored content (skip manifest-sha header line).
      grep -v '^manifest-sha:' "$cache_file"
      return 0
    fi
  fi

  # Cache miss or stale — create dirs and rewrite under lock.
  mkdir -p "$cache_dir"

  local lock_rc=0
  with_lock "$cache_file" _orch_detect_write_cache "$dir" "$cache_file" || lock_rc=$?
  if [[ $lock_rc -ne 0 ]]; then
    printf 'orch-detect: lock timeout on %s — running detection directly\n' "$cache_file" >&2
    # Run detection directly so the caller isn't silently blocked.
    _orch_detect_write_cache "$dir" "$cache_file"
  fi

  # Return result (skip manifest-sha header line).
  grep -v '^manifest-sha:' "$cache_file"
}
