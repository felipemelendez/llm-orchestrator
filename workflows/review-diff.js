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
        },
        required: ['file', 'line', 'severity', 'confidence', 'claim'],
      },
    },
  },
  required: ['findings'],
}

const isBlocking = (f) => f.severity === 'critical' || f.severity === 'important'
const passesFloor = (f) => typeof f.confidence === 'number' && f.confidence >= CONFIDENCE_FLOOR

// --- Stage 1: spec compliance (the gate) ----------------------------------
phase('Spec')
const stage1 = await agent(
  `You are the spec-compliance reviewer. Do not trust any implementer report — read the diff against the spec yourself.\n\nSPEC:\n${specText}\n\nPLAN:\n${planText}\n\nDIFF:\n${diff}\n\nReturn findings where the diff fails to implement the spec/plan. Only raise a finding if at least 80% confident it is real; put weaker observations nowhere (omit them). Severity: critical = breaks a contract/spec requirement; important = meaningful gap; minor = nit.`,
  { agentType: 'llm-orchestrator:orch-spec-reviewer', schema: FINDINGS_SCHEMA, label: 'spec-compliance', phase: 'Spec' }
)

const specFindings = (stage1?.findings || []).filter(passesFloor)
const specBlocks = specFindings.filter(isBlocking)

// Early-exit: if the diff does not implement the spec, do NOT pay for the
// code-quality / security reviewers — exactly the cheap-exit the ordered
// markdown flow preserves.
if (specBlocks.length > 0) {
  log(`Stage 1 blocking (${specBlocks.length}) — early-exit before quality/security`)
  // Mirror the normal path's partitioning so the fields mean the same thing on
  // both returns: blocking -> confirmed, minor -> notes. Early-exit findings skip
  // the skeptic verify pass — a blocking spec mismatch is reason enough to stop.
  return {
    earlyExit: true,
    confirmed: specBlocks,
    notes: specFindings.filter((f) => !isBlocking(f)),
    stagesRun: ['spec'],
  }
}

// --- Stage 2/3: quality + conditional security, in parallel ----------------
phase('Quality+Security')
const stage23 = await parallel(
  [
    () =>
      agent(
        `You are the code-quality reviewer. Judge correctness, safety, idiom, minimalism, and test coverage of this diff against the project's conventions.\n\nCONVENTIONS:\n${conventions}\n\nDIFF:\n${diff}\n\nOnly raise a finding if at least 80% confident it is real.`,
        { agentType: 'llm-orchestrator:orch-code-reviewer', schema: FINDINGS_SCHEMA, label: 'code-quality', phase: 'Quality+Security' }
      ),
    securitySensitive
      ? () =>
          agent(
            `You are the security reviewer. This diff matched the security-sensitive token set. Look for injection (SQL/command/path), missing auth checks, exposed secrets/credentials, crypto misuse, unsafe deserialization, SSRF/CSRF, and sensitive data in logs.\n\nDIFF:\n${diff}\n\nOnly raise a finding if at least 80% confident it is real.`,
            { agentType: 'llm-orchestrator:orch-security-reviewer', schema: FINDINGS_SCHEMA, label: 'security', phase: 'Quality+Security' }
          )
      : null,
  ].filter(Boolean)
)

const otherFindings = stage23
  .filter(Boolean)
  .flatMap((r) => r.findings || [])
  .filter(passesFloor)

// Candidate pool = all confidence-passing findings from stages 1-3.
const pool = specFindings.concat(otherFindings)
const toVerify = pool.filter(isBlocking) // skeptics only judge critical+important
const minorNotes = pool.filter((f) => !isBlocking(f)) // minors skip verify -> Notes

// --- Verify: bounded adversarial refute pass -------------------------------
phase('Verify')
let confirmed = toVerify
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
            reason: { type: 'string' },
          },
          required: ['index', 'refuted', 'reason'],
        },
      },
    },
    required: ['verdicts'],
  }

  const results = await parallel(
    batches.map((batch, bi) => () => {
      const listed = batch.map((f, i) => `[${i}] (${f.severity}) ${f.file}:${f.line} — ${f.claim}`).join('\n')
      return agent(
        `You are a skeptical verifier. For each finding below, try hard to REFUTE it against the diff. Default to refuted=true when the evidence is weak or you cannot confirm it from the diff.\n\nDIFF:\n${diff}\n\nFINDINGS:\n${listed}\n\nReturn one verdict per finding by its [index].`,
        { agentType: 'llm-orchestrator:orch-code-reviewer', schema: VERDICT_SCHEMA, label: `verify:${bi}`, phase: 'Verify' }
      ).then((v) => ({ batch, verdicts: v?.verdicts || [] }))
    })
  )

  const survivors = []
  for (const r of results.filter(Boolean)) {
    const refuted = new Set(r.verdicts.filter((v) => v.refuted).map((v) => v.index))
    r.batch.forEach((f, i) => {
      if (!refuted.has(i)) survivors.push(f)
    })
  }
  confirmed = survivors
}

const stagesRun = ['spec', 'quality'].concat(securitySensitive ? ['security'] : [])
log(`confirmed ${confirmed.length} finding(s); ${minorNotes.length} note(s)`)

return {
  earlyExit: false,
  confirmed,
  notes: minorNotes,
  stagesRun,
}
