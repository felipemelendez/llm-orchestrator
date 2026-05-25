#!/usr/bin/env bash
# Tests for orch-detect.sh — toolchain + convention detection + content-hash cache.
#
# Mirror of test-research-gate.sh harness style.
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/scripts/lib/orch-detect.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Guard: library must exist before sourcing.
if [[ ! -f "$LIB" ]]; then
  fail "orch-detect.sh exists at scripts/lib/orch-detect.sh" "file not found: $LIB"
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  exit 1
fi

# Source the library (and its deps via the lib itself).
# shellcheck source=../scripts/lib/orch-detect.sh
source "$LIB"

# ============================================================
# Helpers
# ============================================================

# detect_has <dir> <key> <expected_value>
# Checks that `orch_detect_toolchain <dir>` emits a line "key=<value>".
detect_has() {
  local label="$1" dir="$2" key="$3" expected="$4"
  local out line got
  out=$(orch_detect_toolchain "$dir" 2>/dev/null)
  # Find the line starting with key=
  got=$(printf '%s\n' "$out" | grep -E "^${key}=" | head -1 | cut -d= -f2-)
  if [[ "$got" == "$expected" ]]; then
    ok "$label: ${key}=${expected}"
  else
    fail "$label: ${key}=${expected}" "got: '${got}' (full output: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
}

# detect_missing <dir> <key>
# Checks that `orch_detect_toolchain <dir>` emits NO line for <key>.
detect_missing() {
  local label="$1" dir="$2" key="$3"
  local out
  out=$(orch_detect_toolchain "$dir" 2>/dev/null)
  if printf '%s\n' "$out" | grep -qE "^${key}="; then
    local got
    got=$(printf '%s\n' "$out" | grep -E "^${key}=" | head -1)
    fail "$label: ${key} absent" "unexpectedly found: '${got}'"
  else
    ok "$label: ${key} not emitted"
  fi
}

# ============================================================
# Fixtures
# ============================================================
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Node / package.json fixture ---
NODE_DIR="$TMP/node-project"
mkdir -p "$NODE_DIR"
cat > "$NODE_DIR/package.json" <<'EOF'
{
  "name": "my-app",
  "scripts": {
    "test": "jest",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "build": "tsc"
  }
}
EOF

# --- Python / pyproject.toml fixture ---
PY_DIR="$TMP/py-project"
mkdir -p "$PY_DIR"
cat > "$PY_DIR/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]

[tool.ruff]
line-length = 88

[tool.mypy]
strict = true
EOF

# --- Rust / Cargo.toml fixture ---
RUST_DIR="$TMP/rust-project"
mkdir -p "$RUST_DIR"
cat > "$RUST_DIR/Cargo.toml" <<'EOF'
[package]
name = "my-crate"
version = "0.1.0"
EOF

# --- Go / go.mod fixture ---
GO_DIR="$TMP/go-project"
mkdir -p "$GO_DIR"
cat > "$GO_DIR/go.mod" <<'EOF'
module example.com/myapp

go 1.21
EOF

# --- Makefile fixture ---
MAKE_DIR="$TMP/make-project"
mkdir -p "$MAKE_DIR"
cat > "$MAKE_DIR/Makefile" <<'EOF'
.PHONY: test lint build

test:
	go test ./...

lint:
	golangci-lint run

build:
	go build ./...
EOF

# --- Empty dir fixture ---
EMPTY_DIR="$TMP/empty-project"
mkdir -p "$EMPTY_DIR"

# ============================================================
# Section 1: Node / package.json
# ============================================================
printf '%s== package.json detection ==%s\n' "$DIM" "$RESET"

detect_has   "package.json" "$NODE_DIR" "test"      "npm run test"
detect_has   "package.json" "$NODE_DIR" "lint"      "npm run lint"
detect_has   "package.json" "$NODE_DIR" "typecheck" "npm run typecheck"
detect_has   "package.json" "$NODE_DIR" "build"     "npm run build"

# ============================================================
# Section 2: Python / pyproject.toml
# ============================================================
printf '\n%s== pyproject.toml detection ==%s\n' "$DIM" "$RESET"

detect_has   "pyproject.toml" "$PY_DIR" "test"     "pytest"
detect_has   "pyproject.toml" "$PY_DIR" "lint"     "ruff check"
detect_has   "pyproject.toml" "$PY_DIR" "typecheck" "mypy"

# ============================================================
# Section 3: Rust / Cargo.toml
# ============================================================
printf '\n%s== Cargo.toml detection ==%s\n' "$DIM" "$RESET"

detect_has   "Cargo.toml" "$RUST_DIR" "test" "cargo test"
detect_has   "Cargo.toml" "$RUST_DIR" "lint" "cargo clippy"

# ============================================================
# Section 4: Go / go.mod
# ============================================================
printf '\n%s== go.mod detection ==%s\n' "$DIM" "$RESET"

detect_has   "go.mod" "$GO_DIR" "test" "go test ./..."
detect_has   "go.mod" "$GO_DIR" "lint" "go vet ./..."

# ============================================================
# Section 5: Makefile
# ============================================================
printf '\n%s== Makefile detection ==%s\n' "$DIM" "$RESET"

detect_has   "Makefile" "$MAKE_DIR" "test" "make test"

# ============================================================
# Section 6: Empty dir → nothing emitted
# ============================================================
printf '\n%s== empty dir detection ==%s\n' "$DIM" "$RESET"

EMPTY_OUT=$(orch_detect_toolchain "$EMPTY_DIR" 2>/dev/null)
if [[ -z "$EMPTY_OUT" ]]; then
  ok "empty dir → no toolchain lines emitted"
else
  fail "empty dir → no toolchain lines emitted" "got: $EMPTY_OUT"
fi

# ============================================================
# Section 7: Safety — no destructive commands emitted
# ============================================================
printf '\n%s== safety: no destructive commands ==%s\n' "$DIM" "$RESET"

DESTROY_DIR="$TMP/destroy-project"
mkdir -p "$DESTROY_DIR"
cat > "$DESTROY_DIR/package.json" <<'EOF'
{
  "scripts": {
    "test": "jest",
    "deploy": "kubectl apply -f k8s/",
    "publish": "npm publish",
    "release": "semantic-release"
  }
}
EOF

DESTROY_OUT=$(orch_detect_toolchain "$DESTROY_DIR" 2>/dev/null)

for bad_key in deploy publish release; do
  if printf '%s\n' "$DESTROY_OUT" | grep -qE "^${bad_key}="; then
    fail "destructive key '${bad_key}' must not be emitted" \
         "found: $(printf '%s\n' "$DESTROY_OUT" | grep -E "^${bad_key}=")"
  else
    ok "destructive key '${bad_key}' suppressed"
  fi
done

# test must still flow through
detect_has "destructive fixture" "$DESTROY_DIR" "test" "npm run test"

# ============================================================
# Section 8: orch_detect_conventions smoke
# ============================================================
printf '\n%s== orch_detect_conventions smoke ==%s\n' "$DIM" "$RESET"

# Add .prettierrc to node project
echo '{}' > "$NODE_DIR/.prettierrc"

CONV_OUT=$(orch_detect_conventions "$NODE_DIR" 2>/dev/null)
if [[ -n "$CONV_OUT" ]]; then
  ok "orch_detect_conventions returns non-empty for node project"
else
  fail "orch_detect_conventions returns non-empty for node project" "got empty"
fi

# Python project should mention pytest
PY_CONV=$(orch_detect_conventions "$PY_DIR" 2>/dev/null)
if printf '%s' "$PY_CONV" | grep -qi 'pytest'; then
  ok "orch_detect_conventions mentions pytest for pyproject.toml"
else
  fail "orch_detect_conventions mentions pytest for pyproject.toml" "got: $PY_CONV"
fi

# ============================================================
# Section 9: orch_detect_cached — cache round-trip
# ============================================================
printf '\n%s== orch_detect_cached round-trip ==%s\n' "$DIM" "$RESET"

CACHE_HOME="$TMP/cache-home"
export ORCH_HOME="$CACHE_HOME"

# First call: populates cache.
RESULT1=$(orch_detect_cached "$NODE_DIR" 2>/dev/null)
if [[ -n "$RESULT1" ]]; then
  ok "orch_detect_cached first call returns content"
else
  fail "orch_detect_cached first call returns content" "got empty"
fi

# Cache file must exist now.
# Compute project hash the same way the lib does (from $NODE_DIR as cwd-override).
PROJ_HASH=$(cd "$NODE_DIR" && orch_project_hash 2>/dev/null || true)
# Library may use a fixed hash for non-git dirs; check the cache dir exists.
CACHE_FOUND=$(find "$CACHE_HOME/toolchain" -name "config.md" 2>/dev/null | head -1)
if [[ -n "$CACHE_FOUND" ]]; then
  ok "cache file written after first call"
else
  fail "cache file written after first call" "no config.md under $CACHE_HOME/toolchain"
fi

# Second call must return same content (served from cache).
RESULT2=$(orch_detect_cached "$NODE_DIR" 2>/dev/null)
if [[ "$RESULT1" == "$RESULT2" ]]; then
  ok "orch_detect_cached second call returns identical content (cache hit)"
else
  fail "orch_detect_cached second call returns identical content (cache hit)" \
       "first != second"
fi

# Modify the manifest → content hash changes → re-detection fires.
ORIG_PKG=$(cat "$NODE_DIR/package.json")
cat > "$NODE_DIR/package.json" <<'EOF'
{
  "name": "my-app",
  "scripts": {
    "test": "vitest",
    "lint": "eslint .",
    "typecheck": "tsc --noEmit",
    "build": "tsc"
  }
}
EOF

RESULT3=$(orch_detect_cached "$NODE_DIR" 2>/dev/null)

# After manifest change, test= should now use vitest.
if printf '%s' "$RESULT3" | grep -q 'vitest'; then
  ok "orch_detect_cached re-detects after manifest change (test=vitest)"
else
  fail "orch_detect_cached re-detects after manifest change" \
       "expected 'vitest' in output; got: $(printf '%s' "$RESULT3" | tr '\n' '|')"
fi

# Restore original package.json for cleanliness.
printf '%s' "$ORIG_PKG" > "$NODE_DIR/package.json"

# ============================================================
# Section 10: orch_detect_cached uses manifest sha not mtime
# ============================================================
printf '\n%s== cache keyed by sha, not mtime ==%s\n' "$DIM" "$RESET"

SHA_DIR="$TMP/sha-project"
mkdir -p "$SHA_DIR"
cat > "$SHA_DIR/package.json" <<'EOF'
{"scripts":{"test":"jest"}}
EOF

# Seed the cache.
RESULT_SHA1=$(orch_detect_cached "$SHA_DIR" 2>/dev/null)

# Touch file (mtime changes) but keep content identical.
touch "$SHA_DIR/package.json"

RESULT_SHA2=$(orch_detect_cached "$SHA_DIR" 2>/dev/null)
if [[ "$RESULT_SHA1" == "$RESULT_SHA2" ]]; then
  ok "cache hit after touch (content-hash is stable, not mtime-based)"
else
  fail "cache hit after touch (content-hash is stable)" \
       "results differ despite identical content"
fi

unset ORCH_HOME

# ============================================================
# Section 11: orch_regression_baseline + orch_regression_check
# ============================================================
printf '\n%s== regression guard ==%s\n' "$DIM" "$RESET"

REG_HOME="$TMP/reg-home"
export ORCH_HOME="$REG_HOME"

# Create a fake project with a Makefile whose "test" target runs a script.
REG_DIR="$TMP/reg-project"
mkdir -p "$REG_DIR"

# The test runner script — starts passing.
cat > "$REG_DIR/run-tests.sh" <<'RUNNER'
#!/usr/bin/env bash
if [[ -f "$(dirname "$0")/.should-fail" ]]; then
  echo "FAIL: tests failed"
  exit 1
else
  echo "ok 1 - suite passes"
  exit 0
fi
RUNNER
chmod +x "$REG_DIR/run-tests.sh"

cat > "$REG_DIR/Makefile" <<'MAKEFILE'
.PHONY: test
test:
	bash run-tests.sh
MAKEFILE

# Record green baseline.
(cd "$REG_DIR" && orch_regression_baseline "$REG_DIR") 2>/dev/null
BASELINE_RC=$?
if [[ $BASELINE_RC -eq 0 ]]; then
  ok "orch_regression_baseline succeeds when tests pass"
else
  fail "orch_regression_baseline succeeds when tests pass" "exit code: $BASELINE_RC"
fi

# Baseline file must exist in cache.
REG_BASELINE_FILE=$(find "$REG_HOME/toolchain" -name "baseline.md" 2>/dev/null | head -1)
if [[ -n "$REG_BASELINE_FILE" ]]; then
  ok "baseline.md written to cache after orch_regression_baseline"
else
  fail "baseline.md written to cache after orch_regression_baseline" "no baseline.md under $REG_HOME/toolchain"
fi

# Baseline should record status=pass.
if [[ -n "$REG_BASELINE_FILE" ]] && grep -q 'status: pass' "$REG_BASELINE_FILE" 2>/dev/null; then
  ok "baseline.md records status: pass"
else
  fail "baseline.md records status: pass" "contents: $(cat "${REG_BASELINE_FILE:-/dev/null}" 2>/dev/null | tr '\n' '|')"
fi

# While tests still pass, orch_regression_check must return zero.
(cd "$REG_DIR" && orch_regression_check "$REG_DIR") 2>/dev/null
CHECK_STILL_PASS_RC=$?
if [[ $CHECK_STILL_PASS_RC -eq 0 ]]; then
  ok "orch_regression_check returns 0 when suite still passes"
else
  fail "orch_regression_check returns 0 when suite still passes" "exit code: $CHECK_STILL_PASS_RC"
fi

# Now break the tests.
touch "$REG_DIR/.should-fail"

# orch_regression_check must return nonzero and print what regressed.
REG_OUTPUT=$((cd "$REG_DIR" && orch_regression_check "$REG_DIR") 2>&1)
CHECK_FAIL_RC=$?
if [[ $CHECK_FAIL_RC -ne 0 ]]; then
  ok "orch_regression_check returns nonzero when suite was green but now fails"
else
  fail "orch_regression_check returns nonzero when suite was green but now fails" "exit code was 0 (expected nonzero)"
fi

if printf '%s' "$REG_OUTPUT" | grep -qi 'regress'; then
  ok "orch_regression_check prints regression info"
else
  fail "orch_regression_check prints regression info" "got: $(printf '%s' "$REG_OUTPUT" | tr '\n' '|')"
fi

# Fix tests again — check must return zero.
rm -f "$REG_DIR/.should-fail"
(cd "$REG_DIR" && orch_regression_check "$REG_DIR") 2>/dev/null
CHECK_FIXED_RC=$?
if [[ $CHECK_FIXED_RC -eq 0 ]]; then
  ok "orch_regression_check returns 0 after tests are fixed"
else
  fail "orch_regression_check returns 0 after tests are fixed" "exit code: $CHECK_FIXED_RC"
fi

unset ORCH_HOME

# ============================================================
# Section 12: lock-failure fallback — never returns silently empty
# ============================================================
printf '\n%s== lock-failure fallback ==%s\n' "$DIM" "$RESET"

LOCK_HOME="$TMP/lock-fallback-home"
export ORCH_HOME="$LOCK_HOME"

LOCK_DIR="$TMP/lock-project"
mkdir -p "$LOCK_DIR"
cat > "$LOCK_DIR/package.json" <<'EOF'
{"scripts":{"test":"jest"}}
EOF

# Populate the cache first so there's no stale file confusion.
orch_detect_cached "$LOCK_DIR" >/dev/null 2>/dev/null

# Now find the cache file and simulate a held lock by creating the lockdir.
LOCK_CACHE_FILE=$(find "$LOCK_HOME/toolchain" -name "config.md" 2>/dev/null | head -1)
if [[ -z "$LOCK_CACHE_FILE" ]]; then
  fail "lock-fallback: cache file found for setup" "no config.md under $LOCK_HOME/toolchain"
else
  ok "lock-fallback: cache file located for lock simulation"

  # Hold the lock (mkdir-based) so with_lock times out.
  STRANDED_LOCKDIR="${LOCK_CACHE_FILE}.lockdir"
  mkdir -p "$STRANDED_LOCKDIR"

  # Modify the manifest to invalidate the cache sha, forcing the lock path.
  cat > "$LOCK_DIR/package.json" <<'PKGEOF'
{"scripts":{"test":"vitest"}}
PKGEOF

  # Call with a very short timeout so the test doesn't hang.
  FALLBACK_OUT=$(ORCH_LOCK_TIMEOUT=0 orch_detect_cached "$LOCK_DIR" 2>/tmp/lock-fallback-stderr.txt)
  FALLBACK_STDERR=$(cat /tmp/lock-fallback-stderr.txt)

  # Must not return silently empty — must emit detection output.
  if [[ -n "$FALLBACK_OUT" ]]; then
    ok "lock-fallback: output is non-empty even when lock times out"
  else
    fail "lock-fallback: output is non-empty even when lock times out" "got empty — caller would silently fall back"
  fi

  # Must print a diagnostic to stderr.
  if printf '%s' "$FALLBACK_STDERR" | grep -q 'lock timeout\|orch-detect'; then
    ok "lock-fallback: diagnostic printed to stderr on lock timeout"
  else
    fail "lock-fallback: diagnostic printed to stderr on lock timeout" "stderr was: $FALLBACK_STDERR"
  fi

  # Release the simulated held lock.
  rmdir "$STRANDED_LOCKDIR" 2>/dev/null || true
fi

unset ORCH_HOME

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d detect checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
