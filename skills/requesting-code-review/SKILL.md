---
name: requesting-code-review
description: Use when a diff is complete and about to be merged, opened as a PR, or called done. Runs the two-stage review plus an optional security pass. Not for mid-task or incomplete diffs.
---

# Requesting code review

Two required reviews plus one conditional, in order. Each returns an `Issues:` block.

## Two paths

This review can run two ways. The markdown stages below are the **canonical** path. When the
Workflow tool is available, prefer the accelerated path — it adds structured findings and an
adversarial verify pass. The two are not behaviorally identical; routing follows `using-workflows`.

**This flow cannot delegate to the native review skills.** As of Claude Code v2.1.215,
*"Claude no longer runs the `/verify` and `/code-review` skills on its own"* — both carry
`disable-model-invocation: true` and cannot be preloaded into a subagent. They are excellent
**manual** passes (`/code-review xhigh` on a real diff is worth running by hand), but a skill
cannot invoke them, so the plugin's own reviewer agents are the only automatable substrate.

What stays this skill's contract either way: Stage 1 spec compliance (native review checks
correctness, never whether the diff implements the approved spec), the spec-gates-quality
order, and the evidence rules below.

### Preferred path (Workflow tool present)

1. Compute the security boolean from the single source of truth — source
   `scripts/lib/orch-signals.sh` and test the diff against `$ORCH_SIG_SECURITY_DIFF` (the same
   grep shown in Stage 3 below). Do **not** re-derive that regex anywhere else.
2. Run `workflows/review-diff.js`, passing `args = {specText, planText, conventions, diff,
   security_sensitive}`. The script gates Stage 2/3 behind a non-blocking Stage 1 (preserving the
   early-exit below), demotes findings below 0.8 confidence to `Notes:`, and verifies the rest with a bounded
   skeptic pass. It returns `{confirmed, notes, earlyExit, stagesRun, incomplete, failedDimensions}`. `incomplete: true` means a reviewer did not return — that is never an approval.
3. Write the review artifact from that return, using the same report shape as the canonical path.

### Fallback path (no Workflow tool) — canonical

Run the ordered stages below as written. Unchanged.

## Stages

### Stage 1 — Spec compliance

Question: does the diff implement the approved spec/plan?

The reviewer is told explicitly: "Do not trust the implementer's report. Read the diff against the spec."

Inputs to the reviewer:
- The spec (paste, don't reference)
- The plan (paste, don't reference)
- `git diff <base>..HEAD`

### Stage 2 — Code quality

Question: is the code correct, safe, idiomatic, and minimal?

Inputs to the reviewer:
- `git diff <base>..HEAD`
- Project conventions (paste `CLAUDE.md` or relevant section)

Run only after Stage 1 passes or its concerns are addressed.

### Stage 3 — Security (conditional)

Question: does the diff introduce security vulnerabilities?

Run only when the diff touches security-sensitive areas. Check by grepping the diff and changed file paths (source `scripts/lib/orch-signals.sh` for `$ORCH_SIG_SECURITY_DIFF`):

```bash
# Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset here;
# marketplace installs nest under the plugin cache, so fall back to a find).
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
L=$(orch_lib orch-signals.sh); [ -n "$L" ] && source "$L" || echo "orch-signals.sh not found — reinstall the plugin" >&2
echo "$DIFF" | grep -qiE "$ORCH_SIG_SECURITY_DIFF"
```

If the grep matches: dispatch `orch-security-reviewer`. Pass: diff only.
If the grep does not match: skip silently — do not mention Stage 3 in the report.

Stage 3 is advisory. Critical findings block the merge; Important and below are advisory (recorded, non-blocking).

Inputs to the reviewer (when triggered):
- `git diff <base>..HEAD`

Checklist: authentication & authorization, secret/credential handling, input validation & injection (SQL/command/path), crypto misuse, unsafe deserialization, SSRF/CSRF, sensitive data in logs.

## Reviewer response shape

```
Issues:
- Critical:
  - <file:line> — <what + why it matters + suggested fix>
- Important:
  - <file:line> — ...
- Minor:
  - <file:line> — ...

Verdict:
- Ready: yes | no | with-fixes
- <one-line reason>
```

Zero issues is a valid verdict. The reviewer is not measured by findings count.

## What is "Critical" vs "Important" vs "Minor"

- **Critical**: breaks correctness, security, or a contract; must fix before merge.
- **Important**: meaningful problem (perf, maintainability, missing case); fix before continuing in this area.
- **Minor**: style, nit, opinion. Note but don't block.

## Confidence rule

**The threshold belongs to the filter, not the reviewer.** Reviewers are told to report everything they find and tag each finding with a confidence from 0.0 to 1.0. The controller (or `workflows/review-diff.js`) then demotes findings below 0.8 into `Notes:` — nothing is discarded.

Do not instruct a reviewer to be conservative or to report only high-severity issues. Current models follow that literally and report less — recall falls while the false-positive rate barely moves. Anthropic's guidance for Opus 5 is explicit: *"ask it to report everything and filter in a separate pass instead."*

**Critical findings additionally require concrete evidence:** the spec line violated (Stage 1), the failure scenario — specific inputs/state → wrong behavior (Stage 2), or the exploitation path (Stage 3). A Critical claim that can't state its evidence gets downgraded, not surfaced.

Be precise about which half of this rule the literature actually supports. **Stage 1's is cited:** the paper suggests mitigations *"that explicitly force evidence grounding, for example, requiring the rationale to cite the exact requirement clause being violated"* — that is the spec-line rule, near-verbatim. **Stage 2's failure-scenario rule is our own inference.** The paper's nearest text is an observation, not a prescription: 48.2% of findings were "Logic Error" claims made *"often without a falsifiable counterexample."*

Be honest about how strong the rest is. LLM reviewers do systematically over-flag correct code ([arXiv:2603.00539](https://arxiv.org/abs/2603.00539)), but that paper's measured countermeasure is a **fix-guided verification filter** — the reviewer proposes a correction and the correction is *executed* as counterfactual evidence. The same paper finds that prompts asking for more explanation *increase* misjudgement. So a prose scenario is the weak form: it converts "this looks wrong" into a checkable claim, but it is not itself the check. `workflows/review-diff.js` implements the strong form: every finding must carry a `fix`, and the skeptic pass **executes** the fix in a scratch copy where the claim is runnable — a finding survives only if the original misbehaves and the fixed version behaves; equivalence refutes it. Surviving findings are labelled `verifiedBy: executed` (a real counterfactual run) or `verifiedBy: reasoned` (survived argument only — the weak form, used when the claim isn't runnable). Weigh them accordingly.

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
- Inventing Critical issues to pad the report.
- Reporting "looks good" without reading the diff.
- Reviewing before the diff is actually green locally.
