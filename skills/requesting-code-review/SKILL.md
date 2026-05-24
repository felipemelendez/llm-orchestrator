---
name: requesting-code-review
description: You MUST use this when a diff is ready — before merge, before PR, before claiming any feature is done. Runs the two-stage review (spec compliance, then code quality) and integrates the verdict.
---

# Requesting code review

Two reviews, in order. Each returns an `Issues:` block.

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
