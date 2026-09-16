#!/usr/bin/env bash
# cadence-detect.sh — propose a cadence.json for a project. Never writes one.
#
# WHAT
#   cadence-detect.sh [--root <dir>]        print a proposed cadence.json for the
#                                           project at <dir> (default $PWD)
#   cadence-detect.sh --profile <name>      print the shipped defaults for one
#                                           named profile, with no detection
#
#   The proposal always carries EVERY key of the schema, so a human confirming it
#   can see the whole contract rather than the parts that happened to be guessed.
#   Two of those keys are the gate's, not the runner's: lang_globs (which
#   extensions the runner's language covers) and suite_globs (the RUNNABLE
#   subset of the test files). Every profile emits both — empty where the
#   profile does not use them — so no proposal is shaped differently from the
#   next one.
#   Profiles are chosen by what is present: vitest.config.*, jest.config.* or a
#   "jest" key in package.json, pytest.ini / setup.cfg [tool:pytest] /
#   pyproject.toml [tool.pytest / conftest.py, tests/run-all.sh beside
#   tests/test-*.sh. Anything else proposes profile "unknown" with an empty
#   test_cmd, which the gate reports as RUNNER_UNKNOWN rather than guessing.
#
# WHY
#   The gate and the check script must never carry one project's toolchain in
#   their source. This file is the single place the shipped profiles live: the
#   gate asks it for a profile's defaults (--profile) and merges the project's
#   cadence.json over them, so the table cannot drift into two copies.
#
# EXIT CODES
#   0  a proposal was printed (always, when the arguments parse)
#   2  usage error
#
# NOTES
#   Nothing here writes a file, runs a test command, or needs python3.
#   Bash 3.2 compatible.

set -uo pipefail

ROOT_DIR="$PWD"
FORCE_PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root)    shift; ROOT_DIR="${1:-$PWD}" ;;
    --profile) shift; FORCE_PROFILE="${1:-}" ;;
    -h|--help) echo "usage: cadence-detect.sh [--root <dir>] | --profile <name>"; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

detect_profile() {
  local d="$ROOT_DIR"
  if ls "$d"/vitest.config.* >/dev/null 2>&1; then echo vitest; return; fi
  if ls "$d"/jest.config.* >/dev/null 2>&1; then echo jest; return; fi
  if [ -f "$d/package.json" ] && grep -qE '"jest"[[:space:]]*:' "$d/package.json" 2>/dev/null; then echo jest; return; fi
  if [ -f "$d/pytest.ini" ] \
     || { [ -f "$d/setup.cfg" ] && grep -qF '[tool:pytest]' "$d/setup.cfg" 2>/dev/null; } \
     || { [ -f "$d/pyproject.toml" ] && grep -qF '[tool.pytest' "$d/pyproject.toml" 2>/dev/null; } \
     || [ -f "$d/conftest.py" ]; then echo pytest; return; fi
  if [ -f "$d/tests/run-all.sh" ] && ls "$d"/tests/test-*.sh >/dev/null 2>&1; then echo shell-suites; return; fi
  echo unknown
}

if [ -n "$FORCE_PROFILE" ]; then PROFILE="$FORCE_PROFILE"; else PROFILE="$(detect_profile)"; fi

case "$PROFILE" in
  jest) cat <<'JSON'
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "jest", "test_cmd": "npx jest --maxWorkers=2", "summary_re": "^Tests:",
              "fail_count_re": "([0-9]+) failed", "suites_re": "^Test Suites:" },
  "typecheck_cmd": "npx tsc --noEmit", "unused_cmd": "",
  "src_roots": ["src"],
  "prod_globs": ["*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"],
  "test_globs": ["*.test.ts", "*.test.tsx", "*.test.js", "*.spec.ts", "__tests__/"],
  "lang_globs": ["*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"], "suite_globs": [],
  "import_patterns": ["from ['\"][^'\"]*/{base}['\"]", "require\\(['\"][^'\"]*/{base}['\"]\\)", "jest\\.mock\\(['\"][^'\"]*/{base}['\"]"],
  "export_pattern": "^export[[:space:]]+(default[[:space:]]+)?(async[[:space:]]+)?(const|let|function|class|type|interface|enum|abstract class)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*",
  "comment_prefixes": ["//", "/*", "*", "*/"],
  "positive_control": { "file_ext": ".ts", "snippet": "export const __orchPositiveControl: number = 'x';", "expect_marker": "error TS" },
  "wait_patterns": [], "wait_timeout_s": 1800,
  "scratch_dir": "", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
JSON
  ;;
  vitest) cat <<'JSON'
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "vitest", "test_cmd": "npx vitest run", "summary_re": "^[[:space:]]*Tests[[:space:]]",
              "fail_count_re": "([0-9]+) failed", "suites_re": "^[[:space:]]*Test Files" },
  "typecheck_cmd": "npx tsc --noEmit", "unused_cmd": "",
  "src_roots": ["src"],
  "prod_globs": ["*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"],
  "test_globs": ["*.test.ts", "*.test.tsx", "*.test.js", "*.spec.ts", "__tests__/"],
  "lang_globs": ["*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs", "*.cjs"], "suite_globs": [],
  "import_patterns": ["from ['\"][^'\"]*/{base}['\"]", "require\\(['\"][^'\"]*/{base}['\"]\\)", "vi\\.mock\\(['\"][^'\"]*/{base}['\"]"],
  "export_pattern": "^export[[:space:]]+(default[[:space:]]+)?(async[[:space:]]+)?(const|let|function|class|type|interface|enum|abstract class)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*",
  "comment_prefixes": ["//", "/*", "*", "*/"],
  "positive_control": { "file_ext": ".ts", "snippet": "export const __orchPositiveControl: number = 'x';", "expect_marker": "error TS" },
  "wait_patterns": [], "wait_timeout_s": 1800,
  "scratch_dir": "", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
JSON
  ;;
  pytest) cat <<'JSON'
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "pytest", "test_cmd": "python3 -m pytest -q", "summary_re": "(passed|failed|error)",
              "fail_count_re": "([0-9]+) failed", "suites_re": "^collected" },
  "typecheck_cmd": "", "unused_cmd": "",
  "src_roots": ["src", "tests"],
  "prod_globs": ["*.py"],
  "test_globs": ["test_*.py", "*_test.py", "tests/"],
  "lang_globs": ["*.py"], "suite_globs": [],
  "import_patterns": ["from[[:space:]]+[A-Za-z0-9_.]*{base}[[:space:]]+import", "import[[:space:]]+[A-Za-z0-9_.]*{base}([[:space:]]|$)", "patch\\(['\"][^'\"]*{base}"],
  "export_pattern": "^(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*",
  "comment_prefixes": ["#"],
  "positive_control": { "file_ext": ".py", "snippet": "def __orch_positive_control(:", "expect_marker": "SyntaxError" },
  "wait_patterns": [], "wait_timeout_s": 1800,
  "scratch_dir": "", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
JSON
  ;;
  shell-suites) cat <<'JSON'
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "shell-suites", "test_cmd": "", "summary_re": "^(PASS|FAIL)|[0-9]+ (passed|failed)|^FAILED",
              "fail_count_re": "([0-9]+) failed", "suites_re": "" },
  "typecheck_cmd": "", "unused_cmd": "",
  "src_roots": ["scripts", "tests", "hooks", "skills", "commands", "agents", "workflows"],
  "prod_globs": ["scripts/**/*.sh", "scripts/hooks/*.sh", "skills/*/scripts/*.sh", "hooks/*.json"],
  "test_globs": ["tests/**/*.sh"],
  "suite_globs": ["tests/**/test-*.sh", "tests/validate-*.sh"],
  "lang_globs": ["*.sh"],
  "import_patterns": ["{base}\\.sh"],
  "export_pattern": "^[A-Za-z_][A-Za-z0-9_]*\\(\\)",
  "comment_prefixes": ["#"],
  "positive_control": { "file_ext": ".sh", "snippet": "if then; fi", "expect_marker": "syntax error" },
  "wait_patterns": [], "wait_timeout_s": 1800,
  "scratch_dir": "", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
JSON
  ;;
  *) cat <<'JSON'
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "unknown", "test_cmd": "", "summary_re": "", "fail_count_re": "([0-9]+) failed", "suites_re": "" },
  "typecheck_cmd": "", "unused_cmd": "",
  "src_roots": ["."],
  "prod_globs": [], "test_globs": [], "lang_globs": [], "suite_globs": [],
  "import_patterns": [], "export_pattern": "",
  "comment_prefixes": ["#", "//"],
  "positive_control": { "file_ext": "", "snippet": "", "expect_marker": "" },
  "wait_patterns": [], "wait_timeout_s": 1800,
  "scratch_dir": "", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
JSON
  ;;
esac
exit 0
