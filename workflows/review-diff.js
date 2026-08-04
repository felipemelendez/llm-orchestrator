export const meta = {
  name: 'review-diff',
  description: 'Two-stage (+conditional security) code review of a diff: spec-compliance gates code-quality, findings are confidence-filtered and adversarially verified before they surface',
  phases: [
    { title: 'Spec', detail: 'orch-spec-reviewer — does the diff implement the spec? (gate)' },
    { title: 'Quality+Security', detail: 'orch-code-reviewer + conditional orch-security-reviewer, in parallel' },
    { title: 'Verify', detail: 'bounded skeptic pass — refute weak findings before surfacing' },
  ],
}

// ---------------------------------------------------------------------------
// Inputs arrive via `args`, computed by the controller (it has filesystem/shell
// access; this script does not). The controller is the SINGLE place that decides
// security sensitivity — it sources ORCH_SIG_SECURITY_DIFF from
// scripts/lib/orch-signals.sh and passes the boolean in. No security regex here.
//
//   args = {
//     specText, planText, conventions, diff,   // all pasted strings
//     security_sensitive,                       // boolean from orch-signals.sh
//   }
//
// Governing invariant for the return: it must never claim the review was more
// complete, more verified, or cleaner than it was. Every finding a reviewer
// produced is visible in the return, or its loss is counted there. log() is
// display-only — the controller builds its report from the return value alone.
// ---------------------------------------------------------------------------
const a = args || {}
const diff = a.diff || ''
const specText = a.specText || '(no spec on disk)'
const planText = a.planText || '(no plan on disk)'
const conventions = a.conventions || '(no conventions section)'
// Strict boolean: a truthy non-boolean must not dispatch the security reviewer.
const securitySensitive = a.security_sensitive === true

const CONFIDENCE_FLOOR = 0.8
const VERIFY_BATCHES = 4 // hard cap on skeptic agents, so a noisy diff can't blow the budget

// Every finding carries a `fix`: the skeptic pass EXECUTES the proposed fix as
// counterfactual evidence where the claim is runnable (arXiv:2603.00539's
// fix-guided verification filter). A fix that changes nothing observable
// refutes the finding.
const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
          confidence: { type: 'number' },
          claim: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['file', 'line', 'severity', 'confidence', 'claim', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const FIX_RULE =
  ' For each finding, "fix" is the minimal concrete correction — name the file:line and the exact change. The verifier EXECUTES your fix as counterfactual evidence where the claim is runnable, so a finding without a workable fix will not survive.'

const isBlocking = (f) => f.severity === 'critical' || f.severity === 'important'
// Junk elements degrade to a counted drop, never a throw or a surfaced note.
const isFinding = (f) => !!f && typeof f === 'object'
// Callers filter through isFinding first; only real objects reach the floor.
const passesFloor = (f) => typeof f.confidence === 'number' && f.confidence >= CONFIDENCE_FLOOR
// One definition of "this stage produced a usable result", applied to EVERY
// stage — null, `{}`, and a non-array payload all read as a loss, not as clean.
const liveFindings = (r) => !!r && Array.isArray(r.findings)
const liveVerdicts = (v) => !!v && Array.isArray(v.verdicts)
// Verdict reasons are carried into the return; the clip bounds its size.
const clip = (s) => (typeof s === 'string' ? s.slice(0, 500) : '')
// Junk elements in a findings array are dropped and counted — never surfaced.
const droppedOf = (r) => (liveFindings(r) ? r.findings.filter((f) => !isFinding(f)).length : 0)

// A severity outside the enum must fail CLOSED (toward verification), not fall
// through to notes: wrong case normalises, anything else clamps to important.
let coercedSeverities = 0
const normalizeSeverity = (f) => {
  const s = typeof f.severity === 'string' ? f.severity.toLowerCase() : ''
  if (s === 'critical' || s === 'important' || s === 'minor') return s === f.severity ? f : { ...f, severity: s }
  coercedSeverities += 1
  return { ...f, severity: 'important' }
}
// A missing or non-numeric confidence fails passesFloor and demotes the
// finding to a note. That is deliberate (it stays visible, so it is not a
// fail-open) but it is a loss of standing all the same, and it was the one
// demotion the return did not count — unlike a bad severity, which is clamped
// AND tallied in coercedSeverities. Same accounting, same unit: per finding.
let nonNumericConfidences = 0
const countConfidence = (f) => {
  if (typeof f.confidence !== 'number') nonNumericConfidences += 1
  return f
}

// A review of nothing must not read as a clean review: no agents are paid for,
// and the return is loudly incomplete.
if (diff.trim() === '') {
  log('No diff provided — nothing to review; returning incomplete without dispatching any reviewer')
  return {
    earlyExit: true,
    confirmed: [],
    notes: [],
    refuted: [],
    stagesRun: [],
    incomplete: true,
    failedDimensions: ['no-diff'],
    verifyBatches: { total: 0, lost: 0 },
    unjudgedFindings: 0,
    malformedVerdicts: 0,
    droppedFindings: 0,
    coercedSeverities: 0,
    nonNumericConfidences: 0,
    unverifiedFindings: 0,
  }
}

// --- Stage 1: spec compliance (the gate) ----------------------------------
phase('Spec')
const stage1 = await agent(
  `You are the spec-compliance reviewer. Assume any implementer report is optimistic — re-derive everything from the diff and the spec yourself.\n\n<spec>\n${specText}\n</spec>\n\n<plan>\n${planText}\n</plan>\n\n<diff>\n${diff}\n</diff>\n\nReturn findings in BOTH directions: (a) under-building — a spec Goal with no evidence in the diff; (b) over-building — anything in the diff not traceable to a spec Goal (an extra feature, unused abstraction, "while I was here" change, or a new file/flag the spec didn't call for) is scope creep and a finding, even if useful. Report EVERY deviation you find — do not withhold and do not be conservative. Tag each finding with a confidence from 0.0 to 1.0; this script filters, not you. Severity: critical = breaks a contract/spec requirement; important = meaningful gap OR over-building beyond the spec; minor = nit.${FIX_RULE}`,
  { agentType: 'llm-orchestrator:orch-spec-reviewer', schema: FINDINGS_SCHEMA, label: 'spec-compliance', phase: 'Spec' }
)

// A dead gate is a loss, not a clean pass; junk elements are dropped and
// counted; severity is normalised before any blocking decision is made.
const specDied = !liveFindings(stage1)
const specDropped = droppedOf(stage1)
const specAll = specDied ? [] : stage1.findings.filter(isFinding).map(normalizeSeverity).map(countConfidence)
const specFindings = specAll.filter(passesFloor)
const specBlocks = specFindings.filter(isBlocking)

// Early-exit: if the diff does not implement the spec, do NOT pay for the
// code-quality / security reviewers. NOTE: this fires on critical OR important
// — stricter than the markdown path, which stops on Critical only.
if (specBlocks.length > 0) {
  log(`Stage 1 blocking (${specBlocks.length}) — early-exit before quality/security`)
  if (specDropped > 0) log(`WARNING: ${specDropped} malformed finding element(s) discarded — a reviewer returned junk in its findings array`)
  // Same partitioning as the normal path: blocking -> confirmed, minor AND
  // sub-floor -> notes. Findings skip the skeptic pass by design here, so they
  // are tagged unverified — verifiedBy exists on every path.
  const confirmed = specBlocks.map((f) => ({ ...f, verifiedBy: 'unverified' }))
  return {
    earlyExit: true,
    confirmed,
    notes: specFindings.filter((f) => !isBlocking(f)).concat(specAll.filter((f) => !passesFloor(f))),
    refuted: [],
    stagesRun: ['spec'],
    // A discarded finding is a loss even on this path: the stage ran, but part
    // of its output was unusable.
    incomplete: specDropped > 0,
    failedDimensions: specDropped > 0 ? ['spec'] : [],
    // Field parity with the normal return: a caller reading a documented field
    // must never get `undefined` on one path only.
    verifyBatches: { total: 0, lost: 0 },
    unjudgedFindings: 0,
    malformedVerdicts: 0,
    droppedFindings: specDropped,
    coercedSeverities,
    nonNumericConfidences,
    unverifiedFindings: confirmed.length,
  }
}

// --- Stage 2/3: quality + conditional security, in parallel ----------------
phase('Quality+Security')
// dimensionNames stays index-aligned with stage23 (spec's loss is concatenated
// onto the RESULT, never prepended here).
const dimensionNames = ['code-quality'].concat(securitySensitive ? ['security'] : [])
const stage23Raw = await parallel(
  [
    () =>
      agent(
        `You are the code-quality reviewer. Judge correctness, safety, idiom, minimalism, and test coverage of this diff against the project's conventions.\n\n<conventions>\n${conventions}\n</conventions>\n\n<diff>\n${diff}\n</diff>\n\nReport EVERY issue you find — do not withhold and do not be conservative. Tag each finding with a confidence from 0.0 to 1.0; this script filters, not you. A critical finding must state the concrete failure scenario in its claim (the specific inputs or state that produce the wrong behavior); if you cannot construct one, use severity important or omit it.${FIX_RULE}`,
        { agentType: 'llm-orchestrator:orch-code-reviewer', schema: FINDINGS_SCHEMA, label: 'code-quality', phase: 'Quality+Security' }
      ),
    securitySensitive
      ? () =>
          agent(
            `You are the security reviewer. This diff matched the security-sensitive token set. Look for injection (SQL/command/path), missing auth checks, exposed secrets/credentials, crypto misuse, unsafe deserialization, SSRF/CSRF, and sensitive data in logs.\n\n<diff>\n${diff}\n</diff>\n\nReport EVERY issue you find — do not withhold and do not be conservative. Tag each finding with a confidence from 0.0 to 1.0; this script filters, not you. A critical finding must name the concrete attack input or exposure path in its claim; if you cannot state one, use severity important or omit it.${FIX_RULE}`,
            { agentType: 'llm-orchestrator:orch-security-reviewer', schema: FINDINGS_SCHEMA, label: 'security', phase: 'Quality+Security' }
          )
      : null,
  ].filter(Boolean)
)
// parallel() must return one slot per thunk; a mis-sized result reads as every
// dimension lost — never as data silently deleted or an index off the end.
const stage23 = Array.isArray(stage23Raw) && stage23Raw.length === dimensionNames.length
  ? stage23Raw
  : dimensionNames.map(() => null)
if (stage23 !== stage23Raw) log(`WARNING: parallel() returned ${Array.isArray(stage23Raw) ? stage23Raw.length : 'no'} result(s) for ${dimensionNames.length} reviewer(s) — treating all as lost`)

// A dimension that CRASHED (or returned junk elements) is not a dimension that
// found nothing: any partial loss puts its stage in failedDimensions.
const stageDropped = stage23.map(droppedOf)
const failedDimensions = (specDied || specDropped > 0 ? ['spec'] : []).concat(
  stage23.map((r, i) => (!liveFindings(r) || stageDropped[i] > 0 ? dimensionNames[i] : null)).filter(Boolean)
)
if (failedDimensions.length) {
  const gate = specDied ? ' The spec GATE did not run.' : ''
  log(`WARNING: ${failedDimensions.join(', ')} did not return a fully usable result — this review is INCOMPLETE.${gate}`)
}

// Only live dimensions contribute findings; junk elements are dropped (counted
// above per stage) and severity is normalised before any partitioning.
const otherAll = stage23.filter(liveFindings).flatMap((r) => r.findings).filter(isFinding).map(normalizeSeverity).map(countConfidence)
const otherFindings = otherAll.filter(passesFloor)
const droppedFindings = specDropped + stageDropped.reduce((x, y) => x + y, 0)
if (droppedFindings > 0) {
  log(`WARNING: ${droppedFindings} malformed finding element(s) discarded — a reviewer returned junk in its findings array`)
}

// Reviewers report everything and tag confidence; the filtering happens HERE,
// once. Sub-floor findings are demoted to notes, never discarded.
const allFindings = specAll.concat(otherAll)
const pool = specFindings.concat(otherFindings)
const toVerify = pool.filter(isBlocking)                       // skeptics judge critical+important
const belowFloor = allFindings.filter((f) => !passesFloor(f))  // low-confidence -> Notes
const minorNotes = pool.filter((f) => !isBlocking(f)).concat(belowFloor)

// --- Verify: bounded adversarial refute pass -------------------------------
phase('Verify')
let confirmed = toVerify
const refutedOut = []
const deadVerifyBatches = []
let totalVerifyBatches = 0
let malformedVerdicts = 0
let unjudgedFindings = 0
if (toVerify.length > 0) {
  // Batch findings into at most VERIFY_BATCHES skeptic agents (not one-per-finding).
  const batchSize = Math.ceil(toVerify.length / VERIFY_BATCHES)
  const batches = []
  for (let i = 0; i < toVerify.length; i += batchSize) batches.push(toVerify.slice(i, i + batchSize))
  totalVerifyBatches = batches.length

  const VERDICT_SCHEMA = {
    type: 'object',
    additionalProperties: false,
    properties: {
      verdicts: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            index: { type: 'number' },
            refuted: { type: 'boolean' },
            method: { type: 'string', enum: ['executed', 'reasoned'] },
            reason: { type: 'string' },
          },
          required: ['index', 'refuted', 'method', 'reason'],
        },
      },
    },
    required: ['verdicts'],
  }

  // Fix-guided verification (arXiv:2603.00539): where the claim is runnable the
  // skeptic EXECUTES the proposed fix as counterfactual evidence; prose
  // refutation is the fallback and stays labelled as such (method: "reasoned").
  const resultsRaw = await parallel(
    batches.map((batch, bi) => () => {
      const listed = batch
        .map((f, i) => `[${i}] (${f.severity}) ${f.file}:${f.line} — CLAIM: ${f.claim}\n    PROPOSED FIX: ${f.fix || '(none given)'}`)
        .join('\n')
      return agent(
        `You are a skeptical verifier with shell access. For each finding below, decide refuted true/false.\n\nPREFER EXECUTION (method: "executed"): when the claim is demonstrable by running code — a reproduction snippet, the file's own tests, a typecheck — verify it counterfactually. NEVER modify the repository or its git state: copy the affected file(s) into a fresh temp dir (mktemp -d), build the minimal reproduction the claim implies, run it against the ORIGINAL code, then apply the finding's PROPOSED FIX in the temp copy and run it again. The finding survives (refuted=false) only if the original actually RAN and misbehaved AND the fixed version behaves. If original and fixed both ran and behave the SAME, the finding is refuted — the fix changed nothing observable, so the claim was noise. IMPORTANT: "could not execute" is NOT equivalence — if the reproduction fails to run at all (missing dependencies, config, import errors unrelated to the claim), you learned nothing; do NOT mark executed and do NOT refute on that basis — drop to the reasoned fallback instead. method: "executed" asserts the original demonstrably ran. Put the commands you ran and the observed outputs in reason.\n\nFALLBACK (method: "reasoned"): when the finding is not runnable (style, missing test coverage, architectural concerns, or execution was impossible in this environment), try hard to REFUTE it against the diff. Default to refuted=true when the evidence is weak — a claim the diff does not support. But being UNABLE to determine is not the same as weak evidence: if you cannot tell either way from the diff, leave refuted=false and say so in reason. Uncertainty must never clear a blocker. A critical finding whose claim states no concrete failure scenario or attack path is weak evidence by definition — refute it unless the diff itself makes the scenario obvious. Do not pad reasons: run code or cite the diff line.\n\n<diff>\n${diff}\n</diff>\n\n<findings>\n${listed}\n</findings>\n\nReturn one verdict per finding by its [index].`,
        { agentType: 'llm-orchestrator:orch-code-reviewer', schema: VERDICT_SCHEMA, label: `verify:${bi}`, phase: 'Verify' }
      ).then((v) =>
        // A null or malformed skeptic return is normalised to null so it lands
        // in the same dead-batch branch a THROW takes — one failure path.
        liveVerdicts(v) ? { batch, verdicts: v.verdicts } : null
      )
    })
  )
  // Same liveness assertion as Stage 2/3: one result slot per batch, or every
  // batch reads as lost.
  const results = Array.isArray(resultsRaw) && resultsRaw.length === batches.length
    ? resultsRaw
    : batches.map(() => null)
  if (results !== resultsRaw) log(`WARNING: parallel() returned ${Array.isArray(resultsRaw) ? resultsRaw.length : 'no'} result(s) for ${batches.length} skeptic batch(es) — treating all as lost`)

  const survivors = []
  results.forEach((r, bi) => {
    // A dead verifier is not a refutation. Fail closed: keep the findings,
    // mark them unverified, and record the loss so `incomplete` fires.
    if (!r) {
      deadVerifyBatches.push(bi)
      batches[bi].forEach((f) => survivors.push({ ...f, verifiedBy: 'unverified' }))
      return
    }
    // Verdict indices are BATCH-LOCAL; anything outside the batch is discarded
    // and counted, so a confused skeptic degrades to "unjudged", never to a
    // false verdict.
    const inRange = (v) =>
      !!v && Number.isInteger(v.index) && v.index >= 0 && v.index < r.batch.length
    const usable = r.verdicts.filter(inRange)
    malformedVerdicts += r.verdicts.length - usable.length

    // A duplicated index is contradiction, not judgement: EVERY verdict for it
    // is discarded (counted per verdict, same unit as out-of-range above) and
    // the finding degrades to unjudged — "uncertainty must never clear a
    // blocker", in either verdict order.
    const seen = {}
    for (const v of usable) seen[v.index] = (seen[v.index] || 0) + 1
    const refuted = new Set()
    const methodOf = {}
    const reasonOf = {}
    const judged = new Set()
    for (const v of usable) {
      if (seen[v.index] > 1) { malformedVerdicts += 1; continue }
      judged.add(v.index)
      // Clamp to the documented enum; strict `=== true` so a truthy string
      // never deletes a blocker.
      methodOf[v.index] = v.method === 'executed' ? 'executed' : 'reasoned'
      reasonOf[v.index] = clip(v.reason)
      if (v.refuted === true) refuted.add(v.index)
    }
    r.batch.forEach((f, i) => {
      if (refuted.has(i)) {
        // A refuted blocker stays visible: the reason is the only record of
        // why it was deleted from `confirmed`.
        refutedOut.push({ ...f, refutedBy: methodOf[i], reason: reasonOf[i] })
        return
      }
      // verifiedBy: "executed" survived a real counterfactual run; "reasoned"
      // survived only argument; "unverified" means nothing judged it.
      const method = judged.has(i) ? methodOf[i] || 'reasoned' : 'unverified'
      if (!judged.has(i)) unjudgedFindings += 1
      const out = { ...f, verifiedBy: method }
      // The evidence behind the verdict, not just its label.
      if (judged.has(i)) out.verifiedReason = reasonOf[i]
      survivors.push(out)
    })
  })
  confirmed = survivors
}

// stagesRun reports what actually ran; tokens match dimensionNames so it and
// failedDimensions are one set. A stage appears in stagesRun if it ran AT ALL
// and in failedDimensions if ANY part of it was lost — partial loss puts it in
// BOTH, and `verifyBatches` gives the degree.
const verifyRanAtAll = totalVerifyBatches > deadVerifyBatches.length
const stagesRun = (specDied ? [] : ['spec']).concat(
  stage23.map((r, i) => (liveFindings(r) ? dimensionNames[i] : null)).filter(Boolean),
  verifyRanAtAll ? ['verify'] : []
)

// Every loss in one list, so `incomplete` covers the verify pass too: a live
// skeptic that judged nothing is as much a loss as a dead one.
const allLosses = failedDimensions.concat(
  deadVerifyBatches.length || unjudgedFindings > 0 ? ['verify'] : []
)
if (deadVerifyBatches.length) {
  log(`WARNING: ${deadVerifyBatches.length}/${totalVerifyBatches} skeptic batch(es) died — their findings are reported UNVERIFIED, not refuted`)
}
if (malformedVerdicts > 0) {
  log(`WARNING: ${malformedVerdicts} verdict(s) discarded — out-of-range or duplicated index`)
}
if (unjudgedFindings > 0) {
  log(`WARNING: ${unjudgedFindings} finding(s) received no verdict and are reported UNVERIFIED`)
}
// The caller's "is this an approval" number: confirmed findings nothing judged.
const unverifiedFindings = confirmed.filter((f) => f.verifiedBy === 'unverified').length
log(`confirmed ${confirmed.length} finding(s); ${refutedOut.length} refuted; ${minorNotes.length} note(s)`)

return {
  earlyExit: false,
  confirmed,
  notes: minorNotes,
  // Findings the skeptic pass deleted, with the method and reason that cleared
  // each — a third category, neither confirmed nor notes. Refutation is a
  // WORKING verify pass, so this does not set `incomplete`.
  refuted: refutedOut,
  stagesRun,
  // Non-empty losses ⇒ the caller must not treat this as an approval, however
  // few findings came back.
  incomplete: allLosses.length > 0,
  failedDimensions: allLosses,
  // Batches (not findings): distinguishes a total verify loss from a partial one.
  verifyBatches: { total: totalVerifyBatches, lost: deadVerifyBatches.length },
  unjudgedFindings,
  // Verdicts discarded for an out-of-range or duplicated index, counted per
  // verdict. The findings they failed to address are in unjudgedFindings.
  malformedVerdicts,
  // Malformed elements discarded from a reviewer's findings array — each is a
  // loss, attributed to its stage in failedDimensions.
  droppedFindings,
  // Findings whose severity was outside the enum and clamped to important.
  coercedSeverities,
  // Findings whose confidence was missing or non-numeric: they demoted to
  // notes (visible, not dropped), counted here the way coerced severities are.
  nonNumericConfidences,
  unverifiedFindings,
}
