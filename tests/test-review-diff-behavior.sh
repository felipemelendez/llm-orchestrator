#!/usr/bin/env bash
# Behavior test for workflows/review-diff.js.
#
# validate-workflows.sh is a STATIC checker — node --check plus a banned-token
# scan. It never executes the script, so it cannot see a wrong return value.
# This test runs the script body against stubbed workflow globals and asserts on
# the object it returns.
#
# The case under test: the Stage-1 spec reviewer dies. `agent()` returns null on
# a user skip or a terminal API error, so `stage1?.findings || []` yields an
# empty finding list — indistinguishable from "the spec reviewer found nothing".
# Before the fix the script then ran Stage 2/3 and returned incomplete:false,
# reporting a review as complete when its gating stage never ran.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }

TMP=$(mktemp -d)
cleanup() { rm -rf "${TMP}" 2>/dev/null || true; }
trap cleanup EXIT

# The workflow engine supplies agent/parallel/pipeline/phase/log/args as globals
# and runs the body in an async context with top-level await. Reproduce that:
# wrap the source in an async function, inject stubs, print the return value.
# Config arrives via env so this file stays free of shell interpolation.
cat > "${TMP}/harness.mjs" <<'HARNESS'
import { readFileSync } from 'node:fs'

// The engine accepts `export const meta` at the top of a script body. `new
// Function` does not, so strip the export keyword — the declaration itself is
// unchanged, and validate-workflows.sh still enforces the pure-literal form.
const src = readFileSync(process.env.WF_SCRIPT, 'utf8')
  .replace(/^[ \t]*export[ \t]+const[ \t]+meta/m, 'const meta')
const specDies = process.env.WF_SPEC_DIES === '1'
const securitySensitive = process.env.WF_SECURITY === '1'

const blockingSpec = process.env.WF_SPEC_BLOCKS === '1'
const BLOCKER = {
  file: 'x', line: '1', severity: 'critical', confidence: 0.9,
  claim: 'spec goal unimplemented', fix: 'implement it',
}

const agent = async (_prompt, opts = {}) => {
  if (opts.label === 'spec-compliance') {
    if (specDies) return null
    return { findings: blockingSpec ? [BLOCKER] : [] }
  }
  if (opts.label === 'code-quality') {
    if (process.env.WF_QUALITY_DIES === '1') return null
    return { findings: process.env.WF_QUALITY_FINDS === '1' ? [BLOCKER, { ...BLOCKER, file: 'y' }] : [] }
  }
  if (opts.label === 'security') return process.env.WF_SECURITY_DIES === '1' ? null : { findings: [] }
  // Verify stage. A skeptic that THROWS is the case that used to delete findings.
  if (process.env.WF_VERIFY_THROWS === '1') throw new Error('skeptic died')
  return { verdicts: [] }
}
const parallel = async (thunks) => {
  const out = []
  for (const t of thunks) {
    try { out.push(await t()) } catch { out.push(null) }
  }
  return out
}
const pipeline = async (items) => items
const phase = () => {}
const log = () => {}
const args = { diff: 'diff --git a/x b/x', security_sensitive: securitySensitive }

// Node globals stay visible on a `new Function` scope chain, so a script that
// reached for console/process/Buffer/timers would pass here and could still
// throw in the engine sandbox. Shadow them with undefined so this harness errs
// toward strictness rather than toward false confidence. (Date/Math.random are
// already caught statically by validate-workflows.sh Layer B.)
const SHADOWED = ['console', 'process', 'Buffer', 'setTimeout', 'setInterval',
                  'setImmediate', 'require', 'globalThis', 'fetch']

const body = new Function(
  'agent', 'parallel', 'pipeline', 'phase', 'log', 'args', ...SHADOWED,
  '"use strict"; return (async () => {' + src + '})()'
)
const result = await body(agent, parallel, pipeline, phase, log, args,
                          ...SHADOWED.map(() => undefined))
process.stdout.write(JSON.stringify(result))
HARNESS

run() { # run <spec_dies> <sec_sensitive> [spec_blocks] [qual_dies] [sec_dies] [qual_finds] [verify_throws]
  WF_SCRIPT="${ROOT}/workflows/review-diff.js" \
  WF_SPEC_DIES="$1" WF_SECURITY="$2" WF_SPEC_BLOCKS="${3:-0}" \
  WF_QUALITY_DIES="${4:-0}" WF_SECURITY_DIES="${5:-0}" \
  WF_QUALITY_FINDS="${6:-0}" WF_VERIFY_THROWS="${7:-0}" \
  node "${TMP}/harness.mjs" 2>&1
}

want() { # want <json> <pattern> <label>
  if ! printf '%s' "$1" | command grep -q -- "$2"; then
    echo "FAIL: $3 — expected /$2/ in: $1"
    fail=1
  fi
}

reject() { # reject <json> <pattern> <label>
  if printf '%s' "$1" | command grep -q -- "$2"; then
    echo "FAIL: $3 — did NOT expect /$2/ in: $1"
    fail=1
  fi
}

# --- Case 1: the spec reviewer dies. The loss must be visible. --------------
DEAD=$(run 1 0)
want   "${DEAD}" '"incomplete":true'          "stage-1 death sets incomplete"
want   "${DEAD}" '"failedDimensions":\["spec' "stage-1 death names spec"
# stagesRun must not claim the gating stage ran when it did not.
reject "${DEAD}" '"stagesRun":\["spec'        "stagesRun honesty"
want   "${DEAD}" '"stagesRun":\["code-quality"\]' "dead spec leaves only the stage that ran"

# --- Case 2: healthy run. The guard must not fire on a normal review. -------
OK=$(run 0 0)
want   "${OK}" '"incomplete":false'  "healthy run stays complete"
want   "${OK}" '"stagesRun":\["spec","code-quality"\]' "healthy run records both stages"

# --- Case 3: security-sensitive healthy run keeps dimension alignment. ------
SEC=$(run 0 1)
want   "${SEC}" '"incomplete":false' "security-sensitive run stays complete"
want   "${SEC}" '"stagesRun":\["spec","code-quality","security"\]' \
                                     "security-sensitive run records all three stages"

# --- Cases 3a/3b: the index-alignment invariant. -----------------------------
# dimensionNames is index-aligned with stage23. Prepending 'spec' to it — the
# mutation the comment above the array forbids — makes a dead code-quality
# reviewer report as a dead spec reviewer. Without these two cases that mutation
# passes the suite, so the invariant the comment defends is untested.
QDEAD=$(run 0 1 0 1 0)
want   "${QDEAD}" '"failedDimensions":\["code-quality"\]' "dead quality names code-quality"
reject "${QDEAD}" '"failedDimensions":\["spec'            "dead quality is not misnamed spec"
reject "${QDEAD}" '"stagesRun":\[[^]]*"code-quality"'     "dead quality is absent from stagesRun"
want   "${QDEAD}" '"incomplete":true'                     "dead quality sets incomplete"

SDEAD=$(run 0 1 0 0 1)
want   "${SDEAD}" '"failedDimensions":\["security"\]' "dead security names security"
reject "${SDEAD}" '"stagesRun":\[[^]]*"security"'     "dead security is absent from stagesRun"
want   "${SDEAD}" '"stagesRun":\["spec","code-quality"\]' "dead security leaves the other two"

# --- Case 4: early exit must honour the documented return shape. ------------
# requesting-code-review/SKILL.md and commands/review.md both tell the caller the
# result carries `incomplete` and `failedDimensions`. Omitting them on this path
# made `result.incomplete` read `undefined` — falsy, so a strict caller silently
# treated a blocked review as a clean one.
EARLY=$(run 0 0 1)
want "${EARLY}" '"earlyExit":true'      "early exit fires on a blocking spec finding"
want "${EARLY}" '"incomplete":false'    "early exit carries incomplete"
want "${EARLY}" '"failedDimensions":\[' "early exit carries failedDimensions"

# --- Cases 5/6: the Verify stage. --------------------------------------------
# Until these existed the stub could never emit a finding, so `toVerify` was
# always empty and the entire verify block never executed — including the branch
# where a thrown skeptic deleted findings a live reviewer had produced.
VOK=$(run 0 0 0 0 0 1 0)
want "${VOK}" '"confirmed":\[' "live findings reach confirmed"
want "${VOK}" '"verifiedBy":"reasoned"' "surviving findings are labelled"
want "${VOK}" '"stagesRun":\["spec","code-quality","verify"\]' "verify stage recorded"
want "${VOK}" '"incomplete":false' "healthy verify stays complete"

VDEAD=$(run 0 0 0 0 0 1 1)
want "${VDEAD}" '"verifiedBy":"unverified"' "a dead skeptic yields unverified, not deleted"
want "${VDEAD}" '"failedDimensions":\["verify"\]' "a dead skeptic is recorded as a loss"
want "${VDEAD}" '"incomplete":true' "a dead skeptic sets incomplete"
reject "${VDEAD}" '"confirmed":\[\]' "a dead skeptic does NOT empty confirmed"
reject "${VDEAD}" '"stagesRun":\[[^]]*"verify"' "a dead skeptic is absent from stagesRun"

if (( fail == 0 )); then
  echo "OK: stage-1 loss reported"
else
  echo "FAILED"
  exit 1
fi
