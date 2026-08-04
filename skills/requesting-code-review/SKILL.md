---
name: requesting-code-review
description: Use when a diff is complete and about to be merged, opened as a PR, or called done. Runs the two-stage review plus an optional security pass. Not for mid-task or incomplete diffs.
---

# Requesting code review

Two required reviews plus one conditional, in order. Each returns an `Issues:` block.

## Two paths

The markdown stages below are canonical and portable. When the Workflow tool is available, prefer
`workflows/review-diff.js`; routing follows `using-workflows`. One difference when comparing
results: the markdown path stops after Stage 1 only on a **Critical** finding, while the workflow
early-exits on **critical or important** — the workflow gates more strictly.

**This flow cannot delegate to the native review skills.** As of Claude Code v2.1.215, `/verify`
and `/code-review` carry `disable-model-invocation: true` — Claude cannot invoke them and they
cannot be preloaded into a subagent. They are excellent manual passes (`/code-review xhigh` on a
real diff is worth running by hand), so the plugin's own reviewer agents are the only automatable
substrate.

On either path the contract is the same: Stage 1 spec compliance (native review checks
correctness, never whether the diff implements the approved spec), spec gates quality, and the
evidence rules below.

### Preferred path (Workflow tool present)

1. Compute the security boolean from the single source of truth — source
   `scripts/lib/orch-signals.sh` and test the diff against `$ORCH_SIG_SECURITY_DIFF` (the same
   grep shown in Stage 3 below). Do not re-derive that regex anywhere else.
2. Run `workflows/review-diff.js` with `args = {specText, planText, conventions, diff,
   security_sensitive}`. The script gates Stage 2/3 behind a non-blocking Stage 1, demotes
   findings below 0.8 confidence to `Notes:`, and verifies the rest with a bounded skeptic pass.
3. Read the return before treating it as an approval. Two questions, two different fields:
   - **"Is this an approval?"** — `unverifiedFindings`: confirmed findings nothing judged, on any
     path.
   - **"Did anything go missing?"** — `incomplete`: a stage produced no usable result, a live
     skeptic left a finding unjudged, or junk was discarded from a findings array. Never an
     approval — but *not* the unverified signal either: the early-exit path ships its blockers
     `unverified` by design with `incomplete: false`.

   `verifiedBy` per confirmed finding: `executed` (survived a real counterfactual run), `reasoned`
   (survived argument only), or `unverified` — the absence of a pass, not a weak pass. `refuted`
   holds findings the skeptic removed, each with the reason; a clean refutation is a *working*
   verify pass and does not set `incomplete`.

   An empty or whitespace-only diff dispatches no reviewer: `earlyExit: true`, `incomplete: true`,
   `failedDimensions: ['no-diff']`. Otherwise `stagesRun` and `failedDimensions` share one token
   set (`spec`, `code-quality`, `security`, `verify`) and a partly-executed stage appears in
   **both**. The counters (`verifyBatches`, `unjudgedFindings`, `malformedVerdicts`,
   `droppedFindings`, `coercedSeverities`) give the degree of loss — non-zero means a degraded
   review. Severity clamping fails *closed* (toward `important`), and each verify batch that did
   not return is counted in `lost`.
4. Write the review artifact from that return, in the same report shape as the canonical path.

### Fallback path (no Workflow tool) — canonical

Run the ordered stages below as written.

## Stages

### Stage 1 — Spec compliance

Question: does the diff implement the approved spec/plan?

Tell the reviewer explicitly: "Do not trust the implementer's report. Read the diff against the
spec." Paste (don't reference) the spec, the plan, and `git diff <base>..HEAD`, each in its own
tag — `<spec>`, `<plan>`, `<diff>` — as the templates in `templates/` do. A diff carries the
``` fences and `##` headings of every markdown file it touches, so a fence is not a boundary the
reviewer can rely on.

### Stage 2 — Code quality

Question: is the code correct, safe, idiomatic, and minimal? Inputs: the diff plus project
conventions (paste `CLAUDE.md` or the relevant section). Run only after Stage 1 passes or its
concerns are addressed.

### Stage 3 — Security (conditional)

Run only when the diff touches security-sensitive areas, per the shared signal:

```bash
# Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset here;
# marketplace installs nest under the plugin cache, so fall back to a find).
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
L=$(orch_lib orch-signals.sh); [ -n "$L" ] && source "$L" || echo "orch-signals.sh not found — reinstall the plugin" >&2
echo "$DIFF" | grep -qiE "$ORCH_SIG_SECURITY_DIFF"
```

Match → dispatch `orch-security-reviewer` with the diff only. No match → skip silently; do not
mention Stage 3 in the report. Stage 3 is advisory: Critical findings block the merge, Important
and below are recorded, non-blocking.

## Severity

**Critical** (breaks correctness, security, or a contract) blocks the merge. **Important** is
fixed before continuing in that area. **Minor** is noted, never blocking. Zero issues is a valid
verdict — the reviewer is not measured by findings count.

Reviewers return `Issues:` grouped by severity, each finding as `<file:line> — what + why it
matters + suggested fix`, plus `Verdict: Ready: yes | no | with-fixes` and a one-line reason.

## Confidence rule

**The threshold belongs to the filter, not the reviewer.** Reviewers report everything they find
and tag each finding with a confidence from 0.0 to 1.0. The controller (or
`workflows/review-diff.js`) demotes findings below 0.8 into `Notes:` — a demoted finding is never
discarded. Only two things leave `confirmed`, both still visible in the return: malformed elements
(dropped, counted as `droppedFindings`, sets `incomplete`) and refuted findings (moved to
`refuted` with the reason).

Do not instruct a reviewer to be conservative or to report only high-severity issues. Current
models follow that literally and report less — recall falls while the false-positive rate barely
moves. Anthropic's guidance for Opus 5 is explicit: *"ask it to report everything and filter in a
separate pass instead."*

**Critical findings additionally require concrete evidence:** the spec line violated (Stage 1),
the failure scenario — specific inputs/state → wrong behavior (Stage 2), or the exploitation path
(Stage 3). A Critical claim that can't state its evidence gets downgraded, not surfaced.

The `verifiedBy` weighting is measured, not stylistic: LLM reviewers systematically over-flag
correct code, and the countermeasure that works is *executing* a proposed fix as counterfactual
evidence — the skeptic pass in `workflows/review-diff.js` — not asking for more explanation, which
*increases* misjudgement ([arXiv:2603.00539](https://arxiv.org/abs/2603.00539)).

## Output (from the controller after both stages)

```
Issues:
- Critical: 0
- Important: 2
- Minor: 4
Notes:
- <findings the reviewer tagged below 0.8 confidence — recorded, never blocking>
Verdict:
- with-fixes — address 2 Important before merging
Next:
- Fix users.ts:42 and api.ts:118. Re-run /llm-orchestrator:review.
```

## Anti-patterns

- One reviewer doing both stages.
- Reviewing before the diff is actually green locally.
