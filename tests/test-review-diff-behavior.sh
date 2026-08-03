#!/usr/bin/env bash
# Behavior test for workflows/review-diff.js.
#
# validate-workflows.sh is a STATIC checker — node --check plus a banned-token
# scan. It never executes the script, so it cannot see a wrong return value.
# This runs the script body against stubbed workflow globals and asserts on the
# object it returns AND on the log lines it emits.
#
# The suite exists because this script's failure mode is silence: every defect
# it has carried reported a review as COMPLETE and CLEAN while a stage did not
# run, or while findings a live reviewer produced were dropped. None of those
# are visible to a linter, and all of them are invisible to a human reading a
# green summary.
#
# Configuration arrives as one JSON blob in WF_CFG so cases stay readable:
#   spec/quality/security:
#     ok | blocks | notes-only | sub-floor | finds | one | five | seven | mixed
#     | many | imp-only | junk-only | junk-blocks | bad-severity | bad-severity-q
#     | floor-edge | sec-finds
#     | null | empty-obj | null-findings | bad-findings | null-element
#   verify:
#     none | refute | reasoned | executed | null | throw | bad-shape
#     | null-verdict | out-of-range | duplicate-index | duplicate-refute-first
#     | triplicate-index | refuted-string | bad-method | long-reason
#   securitySensitive: true | false
#   rawSecurity: any value, passed VERBATIM as args.security_sensitive
#   verifyDeaths: N  (first N batches return null; the rest behave per `verify`)
#   diff: overrides the default diff text (for the empty-diff guard)
#   skewStage / skewVerify: +N/-N elements on the parallel() result at that site
#
# An unrecognised mode THROWS rather than falling through to a clean run — a
# suite built to catch vacuous passes must not contain one.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }

TMP=$(mktemp -d)
cleanup() { rm -rf "${TMP}" 2>/dev/null || true; }
trap cleanup EXIT

cat > "${TMP}/harness.mjs" <<'HARNESS'
import { readFileSync } from 'node:fs'

// The engine accepts `export const meta` at the top of a script body. `new
// Function` does not, so strip the export keyword — the declaration itself is
// unchanged, and validate-workflows.sh still enforces the pure-literal form.
// Global flag: a second top-level export would otherwise be a silent SyntaxError.
const src = readFileSync(process.env.WF_SCRIPT, 'utf8')
  .replace(/^[ \t]*export[ \t]+(const|let|var|function|class)\b/gm, '$1')

const cfg = JSON.parse(process.env.WF_CFG || '{}')
const securitySensitive = cfg.securitySensitive === true
const verifyDeaths = cfg.verifyDeaths || 0

const F = (file, severity, confidence) =>
  ({ file, line: '1', severity, confidence, claim: `claim for ${file}`, fix: `fix ${file}` })

const FINDINGS = {
  ok:             [],
  // Blocking (critical AND important) + sub-floor (minor AND a sub-floor
  // BLOCKER): forces the EARLY-EXIT path with every partition populated.
  blocks:         [F('spec-block', 'critical', 0.9), F('spec-minor', 'minor', 0.9),
                   F('spec-low', 'minor', 0.3), F('spec-imp', 'important', 0.9),
                   F('spec-lowblock', 'critical', 0.5)],
  // A single IMPORTANT must early-exit on its own — the workflow gates on
  // critical OR important, unlike the markdown path (Critical only).
  'imp-only':     [F('spec-imp', 'important', 0.9)],
  // Above floor but NOT blocking: no early exit, so spec findings must survive
  // into the normal path's pool.
  'notes-only':   [F('spec-note', 'minor', 0.9)],
  'sub-floor':    [F('spec-low', 'critical', 0.3)],
  finds:          [F('q1', 'critical', 0.9), F('q2', 'critical', 0.9)],
  // Exactly ONE blocking finding: the verify pass must still run for it.
  one:            [F('solo', 'critical', 0.9)],
  // 5 and 7 do NOT divide evenly into batches — the last PARTIAL batch must
  // still be formed (2 and 9, the old counts, both divide evenly).
  five:           Array.from({ length: 5 }, (_, i) => F(`five${i}`, 'critical', 0.9)),
  seven:          Array.from({ length: 7 }, (_, i) => F(`seven${i}`, 'critical', 0.9)),
  mixed:          [F('m-crit', 'critical', 0.9), F('m-imp', 'important', 0.9),
                   F('m-minor', 'minor', 0.9), F('m-low', 'critical', 0.3)],
  // More findings than VERIFY_BATCHES, so the batching cap is observable.
  many:           Array.from({ length: 9 }, (_, i) => F(`many${i}`, 'critical', 0.9)),
  // Severity outside the enum: wrong case must normalise, junk must clamp to
  // important (fail closed) and be counted.
  'bad-severity': [F('spec-caps', 'Critical', 0.95),
                   { file: 'spec-nosev', line: '1', confidence: 0.95, claim: 'c', fix: 'f' }],
  'bad-severity-q': [F('q-caps', 'CRITICAL', 0.9), F('q-imp', 'Important', 0.9),
                     F('q-weird', 'blocker', 0.9)],
  // Exactly AT the floor and just BELOW it: pins the floor's value and its >=.
  'floor-edge':   [F('at-floor', 'critical', 0.8), F('near-floor', 'critical', 0.79)],
  'sec-finds':    [F('sec-crit', 'critical', 0.9), F('sec-low', 'important', 0.4)],
  'junk-only':    ['junk'],
}

const shaped = (mode) => {
  if (mode === 'null') return null
  if (mode === 'empty-obj') return {}
  if (mode === 'null-findings') return { findings: null }
  if (mode === 'bad-findings') return { findings: 'oops' }
  if (mode === 'null-element') return { findings: [null, F('after-null', 'critical', 0.9)] }
  // Junk elements alongside a BLOCKING finding: the early-exit path must drop
  // and count them, never surface them.
  if (mode === 'junk-blocks') return { findings: [F('spec-block', 'critical', 0.9), null, 'junk'] }
  // A typo'd mode must fail loudly. Falling through to `{findings: []}` made a
  // mistyped case assert against a CLEAN run — a suite whose whole purpose is
  // catching vacuous passes cannot itself pass vacuously.
  if (!(mode in FINDINGS)) throw new Error('unknown findings mode: ' + mode)
  return { findings: FINDINGS[mode] }
}

const V = (index, refuted, method) => ({ index, refuted, method, reason: 'r' })

let batchSeen = 0
const verdictFor = (batchSize) => {
  const mode = cfg.verify || 'none'
  const mine = batchSeen++
  if (mine < verifyDeaths) return null
  switch (mode) {
    case 'null': return null
    case 'throw': throw new Error('skeptic died')
    case 'bad-shape': return { verdicts: 'not-an-array' }
    case 'null-verdict': return { verdicts: [null, V(0, false, 'reasoned')] }
    // Every out-of-range form: too high, negative, and non-integer.
    case 'out-of-range':
      return { verdicts: [V(99, true, 'reasoned'), V(-1, true, 'reasoned'), V(1.5, true, 'reasoned')] }
    // Two verdicts for the SAME finding, disagreeing. Schema-valid — `verdicts`
    // has no uniqueness constraint — so this needs no engine misbehaviour.
    case 'duplicate-index':
      return { verdicts: [V(0, false, 'executed'), V(0, true, 'reasoned'), V(1, false, 'reasoned')] }
    // The refuting verdict FIRST. The finding must NOT be deleted.
    case 'duplicate-refute-first':
      return { verdicts: [V(0, true, 'reasoned'), V(0, false, 'executed'), V(1, false, 'reasoned'), V(2, false, 'reasoned')] }
    // THREE verdicts for one index — a two-verdict fixture alone lets a
    // last-write-wins dedup pass.
    case 'triplicate-index':
      return { verdicts: [V(0, false, 'executed'), V(0, true, 'reasoned'), V(0, true, 'reasoned'), V(1, false, 'reasoned'), V(2, false, 'reasoned')] }
    // `refuted` as a truthy STRING. Must not delete the finding.
    case 'refuted-string':
      return { verdicts: Array.from({ length: batchSize }, (_, i) => V(i, 'false', 'reasoned')) }
    // A `method` outside the schema enum must not reach verifiedBy verbatim.
    case 'bad-method':
      return { verdicts: Array.from({ length: batchSize }, (_, i) => V(i, false, 'vibes')) }
    // A reason longer than the 500-char clip. The return must stay bounded.
    case 'long-reason':
      return { verdicts: Array.from({ length: batchSize }, (_, i) => ({ index: i, refuted: false, method: 'reasoned', reason: 'x'.repeat(600) })) }
    case 'none': return { verdicts: [] }
    case 'refute':
    case 'reasoned':
    case 'executed': {
      const method = mode === 'executed' ? 'executed' : 'reasoned'
      return { verdicts: Array.from({ length: batchSize }, (_, i) => V(i, mode === 'refute', method)) }
    }
    default: throw new Error('unknown verify mode: ' + mode)
  }
}

// The stub dispatches on agentType + schema (not label alone), and asserts the
// prompts still carry their load-bearing invariants — otherwise Stage 3 could
// silently become a second generic code review, the schema could be dropped,
// and FIX_RULE or the skeptic's uncertainty rule could be gutted unnoticed.
const AT = {
  'spec-compliance': 'llm-orchestrator:orch-spec-reviewer',
  'code-quality': 'llm-orchestrator:orch-code-reviewer',
  'security': 'llm-orchestrator:orch-security-reviewer',
}
const must = (cond, msg) => { if (!cond) throw new Error('stub contract: ' + msg) }
const agent = async (prompt, opts = {}) => {
  const props = (opts.schema && opts.schema.properties) || {}
  if (props.verdicts) {
    must(opts.agentType === 'llm-orchestrator:orch-code-reviewer', 'verify agentType')
    must(/^verify:\d+$/.test(opts.label || ''), 'verify label')
    must(prompt.includes('Uncertainty must never clear a blocker.'), 'skeptic uncertainty rule missing')
    must(prompt.includes('NEVER modify the repository'), 'skeptic no-mutation rule missing')
    // Recover the batch size from the prompt's finding list so the stub can
    // emit one verdict per finding without the script telling it.
    const m = prompt.match(/<findings>\n([\s\S]*?)\n<\/findings>/)
    const size = m ? m[1].split('\n').filter((l) => /^\[\d+\]/.test(l)).length : 1
    return verdictFor(size)
  }
  must(props.findings, 'findings schema on a reviewer call')
  must(opts.agentType === AT[opts.label], `agentType/label mismatch: ${opts.label}/${opts.agentType}`)
  must(prompt.includes('EXECUTES your fix as counterfactual evidence'), 'fix rule missing')
  must(prompt.includes('Report EVERY'), 'report-everything instruction missing')
  if (opts.label === 'spec-compliance') return shaped(cfg.spec || 'ok')
  if (opts.label === 'code-quality') return shaped(cfg.quality || 'ok')
  if (opts.label === 'security') return shaped(cfg.security || 'ok')
  throw new Error('unknown reviewer label: ' + opts.label)
}

// skewStage/skewVerify mis-size the parallel() result at that call site, so
// the script's length guards are observable. The first parallel() call is
// Stage 2/3; every later one is the verify fan-out.
let parallelCalls = 0
const parallel = async (thunks) => {
  const out = []
  for (const t of thunks) {
    try { out.push(await t()) } catch { out.push(null) }
  }
  const skew = (parallelCalls++ === 0 ? cfg.skewStage : cfg.skewVerify) || 0
  if (skew < 0) out.length = Math.max(0, out.length + skew)
  for (let i = 0; i < skew; i++) out.push({ findings: [], verdicts: [] })
  return out
}
const pipeline = async (items) => items
const phase = () => {}
const logs = []
const log = (m) => logs.push(m)
const args = {
  diff: 'diff' in cfg ? cfg.diff : 'diff --git a/x b/x',
  security_sensitive: 'rawSecurity' in cfg ? cfg.rawSecurity : securitySensitive,
}

// Node globals stay visible on a `new Function` scope chain, so a script that
// reached for console/process/Buffer/timers would pass here and could still
// throw in the engine sandbox. Shadow them so this harness errs toward
// strictness. `budget` and `workflow` are engine globals this script does not
// use; they are stubbed rather than shadowed so adding a use is not a false red.
const SHADOWED = ['console', 'process', 'Buffer', 'setTimeout', 'setInterval',
                  'setImmediate', 'require', 'globalThis', 'fetch']

const body = new Function(
  'agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
  ...SHADOWED,
  '"use strict"; return (async () => {' + src + '})()'
)

let out
try {
  const result = await body(
    agent, parallel, pipeline, phase, log, args,
    { total: null, spent: () => 0, remaining: () => Infinity },
    async () => { throw new Error('nested workflow not stubbed') },
    ...SHADOWED.map(() => undefined)
  )
  // Flatten the finding lists to plain filename arrays. Asserting "is m-low
  // in notes and NOT in confirmed" with a regex over nested JSON is fragile and
  // was how a disabled confidence floor slipped through unnoticed.
  out = {
    result,
    logs,
    confirmedFiles: (result.confirmed || []).map((f) => f.file),
    noteFiles: (result.notes || []).map((f) => f.file),
    refutedFiles: (result.refuted || []).map((f) => f.file),
  }
} catch (e) {
  out = { threw: String(e && e.message), logs }
}
process.stdout.write(JSON.stringify(out))
HARNESS

run() { # run '<json cfg>'
  WF_SCRIPT="${ROOT}/workflows/review-diff.js" WF_CFG="$1" node "${TMP}/harness.mjs" 2>&1
}

want() { # want <json> <pattern> <label>
  if ! printf '%s' "$1" | command grep -q -- "$2"; then
    echo "FAIL: $3"
    echo "      expected /$2/"
    echo "      got: $1"
    fail=1
  fi
}

reject() { # reject <json> <pattern> <label>
  if printf '%s' "$1" | command grep -q -- "$2"; then
    echo "FAIL: $3"
    echo "      did NOT expect /$2/"
    echo "      got: $1"
    fail=1
  fi
}

# =============================================================================
# 1. The gate. A spec reviewer that produces no usable finding list is a LOSS,
#    not a pass — in every shape, not just null.
# =============================================================================
for mode in null empty-obj null-findings bad-findings; do
  R=$(run "{\"spec\":\"${mode}\"}")
  reject "${R}" '"threw"'                        "gate ${mode}: does not throw"
  want   "${R}" '"incomplete":true'              "gate ${mode}: sets incomplete"
  want   "${R}" '"failedDimensions":\["spec"\]'  "gate ${mode}: names spec"
  reject "${R}" '"stagesRun":\["spec"'           "gate ${mode}: absent from stagesRun"
done
GDEAD=$(run '{"spec":"null"}')
want "${GDEAD}" 'The spec GATE did not run' "gate null: warns loudly in the log"

OK=$(run '{}')
want   "${OK}" '"incomplete":false'                     "healthy: stays complete"
want   "${OK}" '"stagesRun":\["spec","code-quality"\]'  "healthy: both stages recorded"
want   "${OK}" '"failedDimensions":\[\]'                "healthy: no losses"
want   "${OK}" '"refuted":\[\]'                         "healthy: empty refuted list present"
want   "${OK}" '"droppedFindings":0[,}]'                "healthy: zero dropped"
want   "${OK}" '"coercedSeverities":0[,}]'              "healthy: zero coerced"
want   "${OK}" '"unverifiedFindings":0[,}]'             "healthy: zero unverified"

# =============================================================================
# 2. Stage 2/3 gets the SAME liveness test as the gate — the fail-open kept
#    reappearing one stage over.
# =============================================================================
for mode in null empty-obj null-findings bad-findings; do
  R=$(run "{\"quality\":\"${mode}\"}")
  reject "${R}" '"threw"'                                "quality ${mode}: does not throw"
  want   "${R}" '"incomplete":true'                      "quality ${mode}: sets incomplete"
  want   "${R}" '"failedDimensions":\["code-quality"\]'  "quality ${mode}: names code-quality"
  reject "${R}" '"stagesRun":\[[^]]*"code-quality"'      "quality ${mode}: absent from stagesRun"
  reject "${R}" 'oops'                                   "quality ${mode}: no malformed finding leaks"
  want   "${R}" 'INCOMPLETE'                             "quality ${mode}: warns in the log"
done

SDEAD=$(run '{"securitySensitive":true,"security":"null"}')
want   "${SDEAD}" '"failedDimensions":\["security"\]'          "dead security: named"
want   "${SDEAD}" '"stagesRun":\["spec","code-quality"\]'      "dead security: leaves the other two"

# Index alignment: prepending 'spec' to dimensionNames misnames a dead quality.
QDEAD=$(run '{"securitySensitive":true,"quality":"null"}')
want   "${QDEAD}" '"failedDimensions":\["code-quality"\]' "dead quality: named correctly"
reject "${QDEAD}" '"failedDimensions":\["spec'            "dead quality: not misnamed spec"

# Two dimensions dead at once — a dead gate must not mask a dead reviewer.
BOTH=$(run '{"spec":"null","quality":"null"}')
want "${BOTH}" '"failedDimensions":\["spec","code-quality"\]' "both dead: both named"

# =============================================================================
# 3. The security dimension's whole contribution path: its findings must reach
#    the pool, get verified, and put 'security' in stagesRun.
# =============================================================================
SEC=$(run '{"securitySensitive":true,"security":"sec-finds","verify":"reasoned"}')
want "${SEC}" '"stagesRun":\["spec","code-quality","security","verify"\]' "security: recorded in stagesRun"
want "${SEC}" '"confirmedFiles":\["sec-crit"\]'  "security: its blocker reaches confirmed"
want "${SEC}" '"verifiedBy":"reasoned"'          "security: its blocker is verified"
want "${SEC}" '"noteFiles":\["sec-low"\]'        "security: its sub-floor finding is a note"
want "${SEC}" '"incomplete":false'               "security: complete when live"

# security_sensitive must be a STRICT boolean — a truthy non-boolean must not
# dispatch the security reviewer.
RS1=$(run '{"rawSecurity":"yes","security":"sec-finds"}')
RS2=$(run '{"rawSecurity":1,"security":"sec-finds"}')
for R in "${RS1}" "${RS2}"; do
  want   "${R}" '"stagesRun":\["spec","code-quality"\]' "truthy non-boolean: security not dispatched"
  reject "${R}" 'sec-crit'                              "truthy non-boolean: no security findings"
done

# =============================================================================
# 4. Early exit. Same partitioning as the normal path, including sub-floor —
#    and it fires on critical OR important (the markdown path stops on Critical
#    only; that asymmetry is documented, not accidental).
# =============================================================================
EARLY=$(run '{"spec":"blocks"}')
want "${EARLY}" '"earlyExit":true'                    "early exit: fires"
want "${EARLY}" '"incomplete":false'                  "early exit: carries incomplete"
want "${EARLY}" '"failedDimensions":\[\]'             "early exit: carries failedDimensions"
want "${EARLY}" '"verifiedBy":"unverified"'           "early exit: findings tagged unverified"
want "${EARLY}" '"confirmedFiles":\["spec-block","spec-imp"\]' \
                "early exit: critical AND important both confirmed"
want "${EARLY}" '"noteFiles":\["spec-minor","spec-low","spec-lowblock"\]' \
                "early exit: minor, sub-floor, and sub-floor BLOCKER all kept as notes"
want "${EARLY}" '"unverifiedFindings":2[,}]'          "early exit: unverified count matches confirmed"
want "${EARLY}" 'early-exit before quality/security'  "early exit: logged"
# Field parity with the normal return. Every documented field must exist on
# BOTH paths — a caller reading one gets `undefined` otherwise, which is how
# `incomplete` was silently absent here before.
for f in verifyBatches unjudgedFindings malformedVerdicts stagesRun failedDimensions \
         incomplete refuted droppedFindings coercedSeverities unverifiedFindings; do
  want "${EARLY}" "\"${f}\":" "early exit: carries ${f}"
done

# A single important finding early-exits on its own.
IMP=$(run '{"spec":"imp-only"}')
want "${IMP}" '"earlyExit":true'                 "important-only: early-exits"
want "${IMP}" '"confirmedFiles":\["spec-imp"\]'  "important-only: confirmed"

# Junk elements in a BLOCKING spec return: dropped, counted, counted as a loss —
# never surfaced as notes (C1) and never byte-identical to a clean early exit (C3).
JB=$(run '{"spec":"junk-blocks"}')
reject "${JB}" '"threw"'                          "junk blocks: does not throw"
want   "${JB}" '"earlyExit":true'                 "junk blocks: still early-exits"
want   "${JB}" '"confirmedFiles":\["spec-block"\]' "junk blocks: real blocker confirmed"
want   "${JB}" '"noteFiles":\[\]'                 "junk blocks: junk never surfaces as notes"
want   "${JB}" '"droppedFindings":2[,}]'          "junk blocks: both junk elements counted"
want   "${JB}" '"incomplete":true'                "junk blocks: a discarded finding is a loss"
want   "${JB}" '"failedDimensions":\["spec"\]'    "junk blocks: attributed to the stage"
want   "${JB}" 'junk in its findings array'       "junk blocks: warned in the log"

# A sub-floor-only spec return does NOT early-exit (nothing passes the floor to
# block on) — it must still surface the finding as a note on the normal path.
ELOW=$(run '{"spec":"sub-floor"}')
want   "${ELOW}" '"earlyExit":false'          "sub-floor spec: no early exit"
want   "${ELOW}" '"noteFiles":\["spec-low"\]' "sub-floor spec: demoted to notes"
reject "${ELOW}" '"confirmedFiles":\["spec'   "sub-floor spec: not confirmed"

# Above-floor non-blocking spec findings must reach the normal path's pool.
SNOTE=$(run '{"spec":"notes-only"}')
want "${SNOTE}" '"noteFiles":\["spec-note"\]' "spec findings reach the pool on the normal path"

# =============================================================================
# 5. Severity is normalised, not trusted: wrong case maps into the enum, junk
#    clamps to important (fails CLOSED, toward verification) and is counted.
# =============================================================================
BSEV=$(run '{"spec":"bad-severity"}')
want   "${BSEV}" '"earlyExit":true'                "bad severity: still gates"
want   "${BSEV}" '"confirmedFiles":\["spec-caps","spec-nosev"\]' \
                 "bad severity: 'Critical' and absent severity both block"
want   "${BSEV}" '"severity":"critical"'           "bad severity: case is normalised, not clamped"
want   "${BSEV}" '"coercedSeverities":1[,}]'       "bad severity: only the clamp is counted"
BSEVQ=$(run '{"quality":"bad-severity-q","verify":"reasoned"}')
want   "${BSEVQ}" '"confirmedFiles":\["q-caps","q-imp","q-weird"\]' \
                  "bad severity (quality): all three reach the skeptic pass"
reject "${BSEVQ}" '"severity":"blocker"'           "bad severity (quality): junk severity never surfaces"
want   "${BSEVQ}" '"coercedSeverities":1[,}]'      "bad severity (quality): clamp counted"

# =============================================================================
# 6. The confidence floor and the blocking split.
# =============================================================================
MIX=$(run '{"quality":"mixed","verify":"reasoned"}')
want   "${MIX}" '"confirmedFiles":\["m-crit","m-imp"\]' "floor: critical+important confirmed, in order"
want   "${MIX}" '"noteFiles":\["m-minor","m-low"\]'     "floor: minor and sub-floor demoted to notes"
reject "${MIX}" '"confirmedFiles":\[[^]]*m-low'         "floor: sub-floor never reaches confirmed"
reject "${MIX}" '"confirmedFiles":\[[^]]*m-minor'       "floor: minor never reaches confirmed"

# The floor's VALUE and BOUNDARY: exactly 0.8 passes, 0.79 does not.
FE=$(run '{"quality":"floor-edge","verify":"reasoned"}')
want "${FE}" '"confirmedFiles":\["at-floor"\]'  "floor edge: exactly-at-floor is confirmed"
want "${FE}" '"noteFiles":\["near-floor"\]'     "floor edge: just-below-floor is a note"

# =============================================================================
# 7. The verify pass.
# =============================================================================
# Refuted findings are a THIRD category: removed from confirmed, never notes,
# but returned with the method and reason that cleared them (C2/I1). A clean
# refutation is a WORKING verify pass, so incomplete stays false.
REF=$(run '{"quality":"finds","verify":"refute"}')
want   "${REF}" '"confirmed":\[\]'                "refute: refuted findings leave confirmed"
want   "${REF}" '"refutedFiles":\["q1","q2"\]'    "refute: every refuted finding stays visible"
want   "${REF}" '"refutedBy":"reasoned"'          "refute: method recorded"
want   "${REF}" '"reason":"r"'                    "refute: reason recorded"
want   "${REF}" '"incomplete":false'              "refute: a working refutation is not a loss"
reject "${REF}" '"verifiedBy"'                    "refute: nothing survives to be labelled"
reject "${REF}" '"noteFiles":\[[^]]*q1'           "refute: refuted findings are not notes"
want   "${REF}" '2 refuted'                       "refute: logged"

SURV=$(run '{"quality":"finds","verify":"reasoned"}')
want "${SURV}" '"verifiedBy":"reasoned"'                          "survive: labelled reasoned"
want "${SURV}" '"verifiedReason":"r"'                             "survive: verdict reason carried"
want "${SURV}" '"stagesRun":\["spec","code-quality","verify"\]'   "survive: verify recorded"
want "${SURV}" '"incomplete":false'                               "survive: complete"
want "${SURV}" '"refuted":\[\]'                                   "survive: nothing falsely refuted"
want "${SURV}" 'confirmed 2 finding(s)'                           "survive: summary logged"

EXEC=$(run '{"quality":"finds","verify":"executed"}')
want "${EXEC}" '"verifiedBy":"executed"' "executed: method is propagated, not defaulted"

# Exactly ONE blocking finding must still get a skeptic pass.
ONE=$(run '{"quality":"one","verify":"reasoned"}')
want "${ONE}" '"confirmedFiles":\["solo"\]'  "one finding: confirmed"
want "${ONE}" '"verifiedBy":"reasoned"'      "one finding: the verify pass ran for it"
want "${ONE}" '"total":1[,}]'                "one finding: one batch formed"

# 5 and 7 findings: the last PARTIAL batch must be formed, not deleted.
FIVE=$(run '{"quality":"five","verify":"reasoned"}')
want "${FIVE}" '"confirmedFiles":\["five0","five1","five2","five3","five4"\]' \
               "five findings: none deleted by batching"
want "${FIVE}" '"total":3[,}]'  "five findings: 2+2+1 batches"
SEVEN=$(run '{"quality":"seven","verify":"reasoned"}')
want "${SEVEN}" '"confirmedFiles":\["seven0","seven1","seven2","seven3","seven4","seven5","seven6"\]' \
                "seven findings: none deleted by batching"
want "${SEVEN}" '"total":4[,}]'  "seven findings: 2+2+2+1 batches"

# A LIVE skeptic that judges nothing leaves every finding unjudged — that is a
# verify loss, and the findings ship unverified, not silently blessed.
NONE=$(run '{"quality":"finds","verify":"none"}')
want "${NONE}" '"verifiedBy":"unverified"'        "judged nothing: findings unverified"
want "${NONE}" '"unjudgedFindings":2[,}]'         "judged nothing: counted"
want "${NONE}" '"unverifiedFindings":2[,}]'       "judged nothing: unverified count in return"
want "${NONE}" '"incomplete":true'                "judged nothing: sets incomplete"
want "${NONE}" '"failedDimensions":\["verify"\]'  "judged nothing: verify named"
want "${NONE}" '"stagesRun":\[[^]]*"verify"'      "judged nothing: verify DID run"
want "${NONE}" 'received no verdict'              "judged nothing: warned in the log"

# A skeptic that RETURNS null is the documented skip path. It must be treated
# exactly like one that throws — not silently converted into "judged, survived".
for mode in null throw bad-shape; do
  R=$(run "{\"quality\":\"finds\",\"verify\":\"${mode}\"}")
  want   "${R}" '"verifiedBy":"unverified"'      "skeptic ${mode}: findings unverified"
  want   "${R}" '"failedDimensions":\["verify"\]' "skeptic ${mode}: recorded as a loss"
  want   "${R}" '"incomplete":true'              "skeptic ${mode}: sets incomplete"
  want   "${R}" '"unverifiedFindings":2[,}]'     "skeptic ${mode}: unverified count in return"
  reject "${R}" '"confirmed":\[\]'               "skeptic ${mode}: findings not deleted"
  reject "${R}" '"verifiedBy":"reasoned"'        "skeptic ${mode}: never claims a judgement"
  reject "${R}" '"stagesRun":\[[^]]*"verify"'    "skeptic ${mode}: verify absent from stagesRun"
  want   "${R}" 'skeptic batch(es) died'         "skeptic ${mode}: warned in the log"
done

# An out-of-range verdict index addresses no finding. It must not refute one,
# and the finding it failed to address must read as unjudged.
# Every out-of-range form must be discarded: too high, negative, non-integer.
OOR=$(run '{"quality":"finds","verify":"out-of-range"}')
want   "${OOR}" '"verifiedBy":"unverified"'   "out-of-range: finding reads unjudged"
want   "${OOR}" '"unjudgedFindings":2[,}]'    "out-of-range: unjudged findings counted"
want   "${OOR}" '"malformedVerdicts":6[,}]'   "out-of-range: all three discarded, both batches"
want   "${OOR}" 'out-of-range or duplicated'  "out-of-range: warned in the log"
# Batches of 3, so index 1.5 is inside the numeric range and only the
# integer check can reject it. With one finding per batch the check is
# unobservable — 1.5 is out of range either way.
OOR3=$(run '{"quality":"many","verify":"out-of-range"}')
want   "${OOR3}" '"malformedVerdicts":9[,}]'  "out-of-range: a fractional in-range index is still discarded"
want   "${OOR3}" '"unjudgedFindings":9[,}]'   "out-of-range: no finding is judged by a bad index"
want   "${OOR}" '"incomplete":true'           "out-of-range: sets incomplete"
want   "${OOR}" '"failedDimensions":\["verify"\]' "out-of-range: gives the caller a stage to re-run"
reject "${OOR}" '"confirmed":\[\]'            "out-of-range: does not refute by accident"

# Duplicated verdict indices are contradiction, not judgement: EVERY verdict for
# a duplicated index is discarded (counted per verdict), the finding degrades to
# unjudged, and the refuting verdict must not win in ANY order or multiplicity.
# `many` is used so batches hold 3 findings — with one finding per batch, an
# index-1 verdict is out of range and the duplicate case is unobservable.
DUP=$(run '{"quality":"many","verify":"duplicate-index"}')
want "${DUP}" '"verifiedBy":"unverified"'    "duplicate index: degrades to unjudged"
want "${DUP}" '"incomplete":true'            "duplicate index: sets incomplete"
want "${DUP}" '"malformedVerdicts":6[,}]'    "duplicate index: both verdicts discarded, per batch"

DUPR=$(run '{"quality":"many","verify":"duplicate-refute-first"}')
want "${DUPR}" '"confirmedFiles":\["many0"' "duplicate (refute first): the finding is NOT deleted"
want "${DUPR}" '"malformedVerdicts":6[,}]'  "duplicate (refute first): both verdicts discarded, per batch"
want "${DUPR}" '"incomplete":true'          "duplicate (refute first): sets incomplete"

TRIP=$(run '{"quality":"many","verify":"triplicate-index"}')
want "${TRIP}" '"confirmedFiles":\["many0"'  "triplicate: the finding is NOT deleted"
want "${TRIP}" '"malformedVerdicts":9[,}]'   "triplicate: all three verdicts discarded, per batch"
want "${TRIP}" '"unjudgedFindings":3[,}]'    "triplicate: the finding reads unjudged"

# `refuted` typed as a truthy string must not delete a blocking finding.
RSTR=$(run '{"quality":"finds","verify":"refuted-string"}')
want   "${RSTR}" '"confirmedFiles":\["q1","q2"\]' "refuted:'false' does not refute"

# A method outside the schema enum must not reach verifiedBy verbatim.
BM=$(run '{"quality":"finds","verify":"bad-method"}')
reject "${BM}" 'vibes'                    "out-of-enum method is clamped"
want   "${BM}" '"verifiedBy":"reasoned"'  "out-of-enum method falls back to reasoned"

# A null element inside an otherwise valid array must degrade, never throw.
NV=$(run '{"quality":"finds","verify":"null-verdict"}')
reject "${NV}" '"threw"'                "null verdict element: does not throw"
NE=$(run '{"quality":"null-element"}')
reject "${NE}" '"threw"'                          "null finding element: does not throw"
want   "${NE}" '"droppedFindings":1[,}]'          "null finding element: counted"
want   "${NE}" '"incomplete":true'                "null finding element: a loss"
want   "${NE}" '"failedDimensions":\["code-quality","verify"\]' \
               "null finding element: attributed to the stage"
want   "${NE}" 'junk in its findings array'       "null finding element: warned in the log"
# Same on the SPEC stage's normal path (no blocker, so no early exit).
JO=$(run '{"spec":"junk-only"}')
want "${JO}" '"droppedFindings":1[,}]'        "spec junk: counted"
want "${JO}" '"incomplete":true'              "spec junk: a loss"
want "${JO}" '"failedDimensions":\["spec"\]'  "spec junk: attributed to spec"
want "${JO}" '"stagesRun":\["spec","code-quality"\]' "spec junk: spec still RAN (partial loss, both lists)"

# A verdict reason is carried but clipped to 500 chars, so the return is bounded.
# (Literal runs, not \{500\} — BSD grep caps BRE repetition counts at 255.)
X500=$(printf 'x%.0s' $(seq 1 500))
LR=$(run '{"quality":"finds","verify":"long-reason"}')
want   "${LR}" "${X500}"   "long reason: carried up to the clip"
reject "${LR}" "${X500}x"  "long reason: clipped at 500"

# The skeptic fan-out is capped at VERIFY_BATCHES regardless of finding count —
# "one skeptic agent per finding with no cap" is a named anti-pattern in
# skills/using-workflows/SKILL.md.
MANY=$(run '{"quality":"many","verify":"reasoned"}')
want   "${MANY}" '"total":3[,}]'   "cap: 9 findings batch into at most VERIFY_BATCHES skeptics"
reject "${MANY}" '"total":9[,}]'   "cap: not one skeptic per finding"

# =============================================================================
# 8. Partial verify loss must be distinguishable from total loss.
# =============================================================================
PART=$(run '{"quality":"mixed","verify":"reasoned","verifyDeaths":1}')
want "${PART}" '"stagesRun":\[[^]]*"verify"'     "partial: verify IS in stagesRun"
want "${PART}" '"failedDimensions":\["verify"\]' "partial: verify IS in failedDimensions"
want "${PART}" '"incomplete":true'               "partial: sets incomplete"
want "${PART}" '"lost":1[,}]'                    "partial: lost batch count exposed"
want "${PART}" '"unverifiedFindings":1[,}]'      "partial: the dead batch's finding counted unverified"
reject "${PART}" '"lost":0[,}]'                  "partial: not reported as zero loss"

TOTAL=$(run '{"quality":"finds","verify":"null"}')
want   "${TOTAL}" '"lost":2[,}]'                 "total: every batch counted lost"
reject "${TOTAL}" '"stagesRun":\[[^]]*"verify"'  "total: verify absent from stagesRun"

# =============================================================================
# 9. An empty diff is not a clean review of nothing: no agents are dispatched,
#    and the return says loudly that nothing was reviewed.
# =============================================================================
for d in '{"diff":""}' '{"diff":"  \n  "}'; do
  ED=$(run "${d}")
  want   "${ED}" '"earlyExit":true'                "empty diff: early exit"
  want   "${ED}" '"incomplete":true'               "empty diff: incomplete"
  want   "${ED}" '"failedDimensions":\["no-diff"\]' "empty diff: names the cause"
  want   "${ED}" '"stagesRun":\[\]'                "empty diff: no stage ran"
  want   "${ED}" '"confirmed":\[\]'                "empty diff: no findings invented"
  want   "${ED}" 'No diff'                         "empty diff: logged"
  for f in refuted droppedFindings coercedSeverities unverifiedFindings verifyBatches \
           unjudgedFindings malformedVerdicts notes; do
    want "${ED}" "\"${f}\":" "empty diff: carries ${f}"
  done
done

# =============================================================================
# 10. parallel() liveness: a mis-sized result must read as loss, never as data
#     silently deleted (one short) or an uncaught throw (one long).
# =============================================================================
SKS=$(run '{"quality":"finds","skewStage":-1}')
reject "${SKS}" '"threw"'                              "stage skew -1: does not throw"
want   "${SKS}" '"incomplete":true'                    "stage skew -1: incomplete"
want   "${SKS}" '"failedDimensions":\["code-quality"\]' "stage skew -1: every dimension lost"
SKS2=$(run '{"skewStage":1}')
reject "${SKS2}" '"threw"'            "stage skew +1: does not throw"
want   "${SKS2}" '"incomplete":true'  "stage skew +1: incomplete"
SKV=$(run '{"quality":"finds","verify":"reasoned","skewVerify":-1}')
reject "${SKV}" '"threw"'                          "verify skew -1: does not throw"
want   "${SKV}" '"confirmedFiles":\["q1","q2"\]'   "verify skew -1: no finding deleted"
want   "${SKV}" '"verifiedBy":"unverified"'        "verify skew -1: unverified, not blessed"
want   "${SKV}" '"lost":2[,}]'                     "verify skew -1: every batch counted lost"
want   "${SKV}" '"incomplete":true'                "verify skew -1: incomplete"
SKV2=$(run '{"quality":"finds","verify":"reasoned","skewVerify":1}')
reject "${SKV2}" '"threw"'            "verify skew +1: does not throw"
want   "${SKV2}" '"incomplete":true'  "verify skew +1: incomplete"

# =============================================================================
# 11. validate-workflows.sh: a workflows/ dir that exists but is EMPTY must
#     fail, not pass — the skills reference workflows/review-diff.js by name.
# =============================================================================
VW="${TMP}/vw"
mkdir -p "${VW}/tests" "${VW}/workflows"
cp "${ROOT}/tests/validate-workflows.sh" "${VW}/tests/"
if VWOUT=$(bash "${VW}/tests/validate-workflows.sh" 2>&1); then
  echo "FAIL: validate-workflows passes on an empty workflows/ dir"
  echo "      got: ${VWOUT}"
  fail=1
fi
printf '%s' "${VWOUT}" | command grep -q 'workflows/review-diff.js' || {
  echo "FAIL: empty workflows/ dir failure does not name the missing script"; fail=1; }

if (( fail == 0 )); then
  echo "OK: review-diff behavior"
else
  echo "FAILED"
  exit 1
fi
