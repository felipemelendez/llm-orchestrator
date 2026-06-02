---
name: requesting-code-review
description: You MUST use this when a diff is ready — before merge, before a PR, or before claiming any feature done. Runs the two-stage review plus an optional security pass.
---

# Requesting code review

Two required reviews plus one conditional, in order. Each returns an `Issues:` block.

## Two paths

This review can run two ways. The markdown stages below are the **canonical** path. When the
Workflow tool is available, prefer the accelerated path — it adds structured findings and an
adversarial verify pass. The two are not behaviorally identical; routing follows `using-workflows`.

### Preferred path (Workflow tool present)

1. Compute the security boolean from the single source of truth — source
   `scripts/lib/orch-signals.sh` and test the diff against `$ORCH_SIG_SECURITY_DIFF` (the same
   grep shown in Stage 3 below). Do **not** re-derive that regex anywhere else.
2. Run `workflows/review-diff.js`, passing `args = {specText, planText, conventions, diff,
   security_sensitive}`. The script gates Stage 2/3 behind a non-blocking Stage 1 (preserving the
   early-exit below), confidence-filters at ≥80%, and verifies surviving findings with a bounded
   skeptic pass. It returns `{confirmed, notes, earlyExit}`.
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
- Ready to merge: yes | no | with-fixes
- <one-line reason>
```

Zero issues is a valid verdict. The reviewer is not measured by findings count.

## What is "Critical" vs "Important" vs "Minor"

- **Critical**: breaks correctness, security, or a contract; must fix before merge.
- **Important**: meaningful problem (perf, maintainability, missing case); fix before continuing in this area.
- **Minor**: style, nit, opinion. Note but don't block.

## Confidence rule

The reviewer should not raise an Issue unless ≥80% confident it's real. Speculation goes in a separate `Notes:` section, not in `Issues:`.

## Output (from the controller after both stages)

```
Issues:
- Critical: 0
- Important: 2
- Minor: 4
Verdict:
- with-fixes — address 2 Important before merging
Next:
- Fix users.ts:42 and api.ts:118. Re-run /review.
```

## Anti-patterns

- One reviewer doing both stages.
- Inventing Critical issues to pad the report.
- Reporting "looks good" without reading the diff.
- Reviewing before the diff is actually green locally.
