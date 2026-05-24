# <Title>

Date: YYYY-MM-DD
Status: draft | approved

## Problem
- one or two lines describing what's broken or missing

## Goals
- specific, observable, falsifiable
- e.g. "the API returns 401 on expired tokens" — not "improve auth"

## Non-goals
- what we are explicitly not doing
- prevents scope creep in the plan

## Approach
- chosen option, one-line why
- alternatives considered (one line each, why rejected)

## Constraints
- compatibility requirements
- performance requirements
- security requirements

## Research
- Verdict: VERIFIED | COULDN'T_VERIFY | CONTRADICTED-then-revised | none
- Brief: docs/llm-orchestrator/research/YYYY-MM-DD-<slug>-brief.md (or "n/a — no research-relevant signals")
- Libraries verified: <comma-separated with versions> (or "none")
- Notable findings (one line each, only if material to the approach):
  - <library>@<version>: <what changed since training that the approach relies on>

If outcome was COULDN'T_VERIFY, this section explicitly records "proceeding on training knowledge only" so a reviewer knows the gate didn't have current sources. If outcome was CONTRADICTED, the spec's `## Approach` above already incorporates the revision — this section names the original assumption and the source that contradicted it.

## Open questions
- one bullet per question, or "none"
- close every question before approving
