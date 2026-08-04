#!/usr/bin/env bash
# Meta-test: does tests/validate-workflows.sh actually REJECT bad workflows?
#
# It could not. `node --check` returns 0 on invalid syntax for any .js file
# containing `export` (node parses it as ESM), and the validator REQUIRES every
# workflow to begin with `export const meta` — so Layer A had never once been
# able to fail, and "OK: N workflow script(s) validated" was not evidence of
# syntactic validity. The meta check was a trailing-glob prefix test that
# accepted `export const metadata`, `meta = 42`, and a meta with no name.
#
# A validator is only worth its runtime if a defect makes it go red, so this
# suite injects one defect at a time and asserts the validator rejects it. The
# positive controls matter just as much: the ENGINE runs a workflow script as
# an async function body, where top-level `return` and `await` are legal, so a
# checker strict enough to reject them would reject our own shipping script.
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${ROOT}/tests/validate-workflows.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$VALIDATOR" ]] || { printf 'FAIL — not found: %s\n' "$VALIDATOR"; exit 1; }
if ! command -v node >/dev/null 2>&1; then
  # A skip is not a pass. Six sibling suites printed `PASS: ... (skipped)` and
  # smoke.sh grepped the PASS: prefix, so a missing dependency read as green.
  printf 'SKIP: test-validate-workflows — node unavailable, nothing to assert\n'
  exit 0
fi

# The validator scans <its own root>/workflows, so mutations are staged in an
# ISOLATED per-run sandbox copy — never in the real repo. Staging them in
# $ROOT/workflows made this suite unsafe to run concurrently with anything else
# that scans that directory: tests/validate-workflows.sh standalone, and
# tests/test-install.sh's P8 check (which runs the real validator against $ROOT)
# both went red whenever they caught a mutation mid-flight.
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/tests/lib" "$SBX/workflows"
cp "$VALIDATOR" "$SBX/tests/validate-workflows.sh"
cp "$ROOT/tests/lib/check-workflow-script.mjs" "$SBX/tests/lib/"
cp "$ROOT"/workflows/*.js "$SBX/workflows/" 2>/dev/null
VALIDATOR="$SBX/tests/validate-workflows.sh"
MUT="$SBX/workflows/_mutation-under-test.js"

# rejects <name> <script-source>: the validator must exit non-zero.
rejects() {
  local name="$1" src="$2" rc=0
  printf '%s' "$src" > "$MUT"
  bash "$VALIDATOR" >/dev/null 2>&1 || rc=$?
  rm -f "$MUT"
  if [[ $rc -ne 0 ]]; then ok "rejects: $name"
  else fail "rejects: $name" "validator exited 0 — this defect is invisible to it"; fi
}

# accepts <name> <script-source>: the validator must exit 0.
accepts() {
  local name="$1" src="$2" rc=0 out=""
  printf '%s' "$src" > "$MUT"
  out=$(bash "$VALIDATOR" 2>&1) || rc=$?
  rm -f "$MUT"
  if [[ $rc -eq 0 ]]; then ok "accepts: $name"
  else fail "accepts: $name" "rc=$rc — $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

printf '%s== the shipping workflows validate ==%s\n' "$DIM" "$RESET"
rc=0; OUT=$(bash "$VALIDATOR" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then ok "workflows/ as shipped passes"
else fail "workflows/ as shipped passes" "rc=$rc — $(printf '%s' "$OUT" | head -2 | tr '\n' ' ')"; fi

printf '\n%s== syntax defects (the layer that could never fail) ==%s\n' "$DIM" "$RESET"
rejects "invalid syntax below a valid meta" 'export const meta = {name:"b", description:"x"}
function ( { {
'
rejects "unclosed brace" 'export const meta = {name:"b", description:"x"}
const x = {
'
rejects "TypeScript annotation" 'export const meta = {name:"b", description:"x"}
const x: string = "y"
'
rejects "pure garbage, no export at all" 'function ( { {
'

printf '\n%s== meta-shape defects (the trailing-glob blind spot) ==%s\n' "$DIM" "$RESET"
rejects "export const metadata (wrong identifier)" 'export const metadata = {name:"x", description:"y"}
'
rejects "meta is a number" 'export const meta = 42
'
rejects "meta missing name" 'export const meta = { description:"y" }
'
rejects "meta missing description" 'export const meta = { name:"y" }
'
rejects "meta.name is not kebab-case" 'export const meta = { name:"My Workflow", description:"y" }
'
rejects "meta.name is empty" 'export const meta = { name:"", description:"y" }
'
rejects "phases entry without a title" 'export const meta = { name:"a", description:"y", phases:[{detail:"x"}] }
'

printf '\n%s== purity defects (meta must be a pure literal) ==%s\n' "$DIM" "$RESET"
rejects "meta calls a function" 'export const meta = { name: makeName(), description:"y" }
'
rejects "meta reads a variable" 'export const meta = { name: someVar, description:"y" }
'
rejects "meta spreads an object" 'export const meta = { ...base, name:"a", description:"y" }
'

printf '\n%s== runtime-throw builtins (parse-valid; Layer B) ==%s\n' "$DIM" "$RESET"
rejects "Date.now" 'export const meta = { name:"a", description:"y" }
const t = Date.now()
'
rejects "Math.random" 'export const meta = { name:"a", description:"y" }
const r = Math.random()
'
rejects "new Date" 'export const meta = { name:"a", description:"y" }
const d = new Date()
'
rejects "import statement" 'export const meta = { name:"a", description:"y" }
import fs from "fs"
'
rejects "require call" 'export const meta = { name:"a", description:"y" }
const fs = require("fs")
'

printf '\n%s== positive controls: the engine grammar must be accepted ==%s\n' "$DIM" "$RESET"
# These are the reason a .mjs copy is the WRONG checker: top-level return and
# top-level await are illegal in a module and legal in the async function body
# the Workflow engine runs. A checker that rejects them rejects review-diff.js.
accepts "top-level await + top-level return" 'export const meta = { name: "mini", description: "d" }
const r = await agent("hi")
return { r }
'
accepts "phases array with titles" 'export const meta = { name: "mini", description: "d", phases: [{title:"A"},{title:"B",detail:"x"}] }
phase("A")
return {}
'
accepts "template literal in a prompt" 'export const meta = { name: "mini", description: "d" }
const items = ["a","b"]
const rs = await parallel(items.map(i => () => agent(`review ${i}`)))
return { rs }
'
# Found by cold review, all fail-safe (they rejected VALID input):
# the declaration regex was unanchored, so the phrase inside a comment — which
# this repo's own docs and checker header both contain — made the scanner
# parse the comment's example object.
accepts "the phrase appears in a comment above the real meta" '// Every workflow must start with `export const meta = { name, description }`.
export const meta = { name: "commented", description: "d" }
return {}
'
# No regex-literal state: `/["'"'"']/g` left the walker inside a phantom string
# and `/[}]/` ended the object early.
accepts "regex literal containing quote chars in meta" 'export const meta = { name: "rx", description: "d", strip: /["'"'"']/g }
return {}
'
accepts "regex literal containing a brace in meta" 'export const meta = { name: "rx2", description: "d", closer: /[}]/ }
return {}
'
accepts "regex with a counted quantifier in meta" 'export const meta = { name: "rx3", description: "d", two: /^\d{2}$/ }
return {}
'
accepts "leading comments before meta" '// a comment
// another
export const meta = { name: "mini", description: "d" }
return {}
'

TOTAL=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-validate-workflows (%d checks)%s\n' "$GREEN" "$TOTAL" "$RESET"
  exit 0
fi
printf '%sFAIL: test-validate-workflows — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
exit 1
