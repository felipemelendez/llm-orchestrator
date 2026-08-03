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
// ---------------------------------------------------------------------------
const a = args || {}
const diff = a.diff || ''
const specText = a.specText || '(no spec on disk)'
const planText = a.planText || '(no plan on disk)'
const conventions = a.conventions || '(no conventions section)'
const securitySensitive = a.security_sensitive === true

const CONFIDENCE_FLOOR = 0.8
const VERIFY_BATCHES = 4 // hard cap on skeptic agents, so a noisy diff can't blow the budget

// Every finding carries a `fix` — the minimal concrete correction. That is not
// decoration: the skeptic pass executes the proposed fix as COUNTERFACTUAL
// evidence where the claim is runnable (arXiv:2603.00539's fix-guided
// verification filter — the paper's measured countermeasure, FNR 54.8%→16.3%
// on HumanEval). A finding whose fix changes nothing observable is refuted.
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
const passesFloor = (f) => typeof f.confidence === 'number' && f.confidence >= CONFIDENCE_FLOOR

// --- Stage 1: spec compliance (the gate) ----------------------------------
phase('Spec')
const stage1 = await agent(
  `You are the spec-compliance reviewer. Assume any implementer report is optimistic — re-derive everything from the diff and the spec yourself.\n\n<spec>\n${specText}\n</spec>\n\n<plan>\n${planText}\n</plan>\n\n<diff>\n${diff}\n</diff>\n\nReturn findings in BOTH directions: (a) under-building — a spec Goal with no evidence in the diff; (b) over-building — anything in the diff not traceable to a spec Goal (an extra feature, unused abstraction, "while I was here" change, or a new file/flag the spec didn't call for) is scope creep and a finding, even if useful. Report EVERY deviation you find — do not withhold and do not be conservative. Tag each finding with a confidence from 0.0 to 1.0; this script filters, not you. Severity: critical = breaks a contract/spec requirement; important = meaningful gap OR over-building beyond the spec; minor = nit.${FIX_RULE}`,
  { agentType: 'llm-orchestrator:orch-spec-reviewer', schema: FINDINGS_SCHEMA, label: 'spec-compliance', phase: 'Spec' }
)

// A dead Stage 1 is not a clean Stage 1. `agent()` returns null when the user
// skips it or the subagent dies on a terminal API error, so `stage1?.findings`
// collapses a crashed gate and a passing gate into the same empty list. Stage
// 2/3 already refuse to report a clean result while a dimension is missing
// (see below); the gate itself was never given the same guard, so a dead spec
// reviewer produced a review marked complete whose gating stage never ran.
// Covers every shape that yields no usable finding list, not just null — the
// `?.` on the next line is itself an admission that the return isn't trusted,
// and `{}` or `{findings: null}` would otherwise read as a clean gate.
const specDied = !stage1 || !Array.isArray(stage1.findings)
const specAll = stage1?.findings || []
const specFindings = specAll.filter(passesFloor)
const specBlocks = specFindings.filter(isBlocking)

// Early-exit: if the diff does not implement the spec, do NOT pay for the
// code-quality / security reviewers — exactly the cheap-exit the ordered
// markdown flow preserves.
if (specBlocks.length > 0) {
  log(`Stage 1 blocking (${specBlocks.length}) — early-exit before quality/security`)
  // Mirror the normal path's partitioning so the fields mean the same thing on
  // both returns: blocking -> confirmed, minor -> notes. Early-exit findings skip
  // the skeptic verify pass — a blocking spec mismatch is reason enough to stop.
  // `incomplete`/`failedDimensions` are part of the documented return shape
  // (skills/requesting-code-review/SKILL.md, commands/review.md). Omitting them
  // here made a caller reading `result.incomplete` get `undefined` on this path.
  // Both are literal here: reaching this branch requires specBlocks.length > 0,
  // which requires findings, which requires a live Stage 1 — so specDied is
  // necessarily false and no dimension was lost.
  return {
    earlyExit: true,
    confirmed: specBlocks,
    notes: specFindings.filter((f) => !isBlocking(f)),
    stagesRun: ['spec'],
    incomplete: false,
    failedDimensions: [],
  }
}

// --- Stage 2/3: quality + conditional security, in parallel ----------------
phase('Quality+Security')
const stage23 = await parallel(
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

// A dimension that CRASHED is not a dimension that found nothing. parallel()
// resolves a failed thunk to null, so `.filter(Boolean)` silently converted a
// dead security reviewer into a clean security review. Track the losses and
// refuse to report a clean result while any dimension is missing.
// dimensionNames stays index-aligned with stage23 (1 or 2 entries). Do NOT
// prepend 'spec' to it — stage23[0] is code-quality, so a prepended name would
// report a dead code-quality reviewer as a dead spec reviewer. The spec loss is
// concatenated onto the RESULT instead.
const dimensionNames = ['code-quality'].concat(securitySensitive ? ['security'] : [])
const failedDimensions = (specDied ? ['spec'] : []).concat(
  stage23.map((r, i) => (r ? null : dimensionNames[i])).filter(Boolean)
)
if (failedDimensions.length) {
  const gate = specDied ? ' The spec GATE did not run.' : ''
  log(`WARNING: ${failedDimensions.join(', ')} did not return — this review is INCOMPLETE.${gate}`)
}

const otherAll = stage23.filter(Boolean).flatMap((r) => r.findings || [])
const otherFindings = otherAll.filter(passesFloor)

// Reviewers report everything and tag confidence; the filtering happens HERE, once.
// Sub-floor findings are demoted to notes, never discarded — a finding the reviewer
// was unsure about is still a finding a human may want to scan.
const allFindings = specAll.concat(otherAll)
const pool = specFindings.concat(otherFindings)
const toVerify = pool.filter(isBlocking)                       // skeptics judge critical+important
const belowFloor = allFindings.filter((f) => !passesFloor(f))  // low-confidence -> Notes
const minorNotes = pool.filter((f) => !isBlocking(f)).concat(belowFloor)

// --- Verify: bounded adversarial refute pass -------------------------------
phase('Verify')
let confirmed = toVerify
const deadVerifyBatches = []
if (toVerify.length > 0) {
  // Batch findings into at most VERIFY_BATCHES skeptic agents (not one-per-finding).
  const batchSize = Math.ceil(toVerify.length / VERIFY_BATCHES)
  const batches = []
  for (let i = 0; i < toVerify.length; i += batchSize) {
    batches.push(toVerify.slice(i, i + batchSize))
  }

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

  // Fix-guided verification (arXiv:2603.00539): where the claim is runnable,
  // the skeptic EXECUTES the reviewer's proposed fix as counterfactual
  // evidence instead of arguing about a prose scenario — the same paper finds
  // that asking for more explanation *increases* misjudgement. Prose refutation
  // is the fallback for non-runnable findings (style, missing tests,
  // architecture), and stays labelled as such (method: "reasoned").
  const results = await parallel(
    batches.map((batch, bi) => () => {
      const listed = batch
        .map((f, i) => `[${i}] (${f.severity}) ${f.file}:${f.line} — CLAIM: ${f.claim}\n    PROPOSED FIX: ${f.fix || '(none given)'}`)
        .join('\n')
      return agent(
        `You are a skeptical verifier with shell access. For each finding below, decide refuted true/false.\n\nPREFER EXECUTION (method: "executed"): when the claim is demonstrable by running code — a reproduction snippet, the file's own tests, a typecheck — verify it counterfactually. NEVER modify the repository or its git state: copy the affected file(s) into a fresh temp dir (mktemp -d), build the minimal reproduction the claim implies, run it against the ORIGINAL code, then apply the finding's PROPOSED FIX in the temp copy and run it again. The finding survives (refuted=false) only if the original actually RAN and misbehaved AND the fixed version behaves. If original and fixed both ran and behave the SAME, the finding is refuted — the fix changed nothing observable, so the claim was noise. IMPORTANT: "could not execute" is NOT equivalence — if the reproduction fails to run at all (missing dependencies, config, import errors unrelated to the claim), you learned nothing; do NOT mark executed and do NOT refute on that basis — drop to the reasoned fallback instead. method: "executed" asserts the original demonstrably ran. Put the commands you ran and the observed outputs in reason.\n\nFALLBACK (method: "reasoned"): when the finding is not runnable (style, missing test coverage, architectural concerns, or execution was impossible in this environment), try hard to REFUTE it against the diff. Default to refuted=true when the evidence is weak — a claim the diff does not support. But being UNABLE to determine is not the same as weak evidence: if you cannot tell either way from the diff, leave refuted=false and say so in reason. Uncertainty must never clear a blocker. A critical finding whose claim states no concrete failure scenario or attack path is weak evidence by definition — refute it unless the diff itself makes the scenario obvious. Do not pad reasons: run code or cite the diff line.\n\n<diff>\n${diff}\n</diff>\n\n<findings>\n${listed}\n</findings>\n\nReturn one verdict per finding by its [index].`,
        { agentType: 'llm-orchestrator:orch-code-reviewer', schema: VERDICT_SCHEMA, label: `verify:${bi}`, phase: 'Verify' }
      ).then((v) => ({ batch, verdicts: v?.verdicts || [] }))
    })
  )

  const survivors = []
  results.forEach((r, bi) => {
    // A skeptic batch whose thunk THREW resolves to null (parallel() never
    // rejects). `results.filter(Boolean)` used to drop it, deleting every
    // blocking finding it carried — findings a live reviewer had actually
    // produced — while `incomplete` stayed false. A dead verifier is not a
    // refutation. Fail closed: keep the findings, mark them unverified, and
    // record the loss so the caller's `incomplete` check fires.
    //
    // Note the asymmetry this removes: a skeptic that RETURNED null was already
    // safe (`v?.verdicts || []` refutes nothing, so findings survived), while a
    // skeptic that THREW silently cleared them. Same event, opposite outcomes.
    if (!r) {
      deadVerifyBatches.push(bi)
      batches[bi].forEach((f) => survivors.push({ ...f, verifiedBy: 'unverified' }))
      return
    }
    const refuted = new Set(r.verdicts.filter((v) => v.refuted).map((v) => v.index))
    const methodOf = {}
    for (const v of r.verdicts) methodOf[v.index] = v.method
    r.batch.forEach((f, i) => {
      // verifiedBy makes the evidence strength visible downstream: "executed"
      // survived a real counterfactual run; "reasoned" survived only argument;
      // "unverified" means the skeptic died and nothing judged it.
      if (!refuted.has(i)) survivors.push({ ...f, verifiedBy: methodOf[i] || 'reasoned' })
    })
  })
  confirmed = survivors
}

// stagesRun reports what actually ran, so it must be derived from the same
// evidence as failedDimensions — every hardcoded entry is a stage that claims
// to have run whether or not it did. Tokens match dimensionNames exactly, so
// `stagesRun` minus `failedDimensions` is a meaningful set operation for a
// caller; they previously disagreed ('quality' vs 'code-quality').
const stagesRun = (specDied ? [] : ['spec']).concat(
  stage23.map((r, i) => (r ? dimensionNames[i] : null)).filter(Boolean),
  toVerify.length > 0 && deadVerifyBatches.length === 0 ? ['verify'] : []
)

// Every lost stage in one list, so `incomplete` covers the verify pass too.
const allLosses = failedDimensions.concat(deadVerifyBatches.length ? ['verify'] : [])
if (deadVerifyBatches.length) {
  log(`WARNING: ${deadVerifyBatches.length} skeptic batch(es) died — their findings are reported UNVERIFIED, not refuted`)
}
log(`confirmed ${confirmed.length} finding(s); ${minorNotes.length} note(s)`)

return {
  earlyExit: false,
  confirmed,
  notes: minorNotes,
  stagesRun,
  // Non-empty ⇒ a reviewer or a skeptic died. The caller must not treat this as
  // an approval, regardless of how few findings came back.
  incomplete: allLosses.length > 0,
  failedDimensions: allLosses,
}
