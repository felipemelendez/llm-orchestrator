---
name: research-classifier
description: Use when about to invoke brainstorming or writing-plans, before a spec or plan is committed. Decides whether to verify API surfaces against current docs first.
---

# Research classifier

The cheapest gate before research fires, and biased toward SKIP: over-triggering makes every design conversation start with an unwanted wait, while under-triggering merely makes the feature invisible. Most tasks skip. Detail lives in two reference files: [`STRATEGY.md`](./STRATEGY.md) (aggressiveness levels, stakes ladder, capability survey, MCP-nudge rules) and [`EXAMPLES.md`](./EXAMPLES.md) (the curated input→outcome table).

## When to invoke

Two fixed trigger points, never every turn:

- **Trigger A — pre-spec:** `brainstorming` runs it on the user's raw task text, before clarifying questions.
- **Trigger B — pre-plan:** `writing-plans` runs it on the spec's `## Approach`, before any plan file is written.

Not for arbitrary user messages, `/llm-orchestrator:debug`, `/llm-orchestrator:verify`, `/llm-orchestrator:finish`, or non-design conversation. The hook layer doesn't enforce these points — `orch-research-gate.sh` is content-addressed and fires wherever a prompt matches the shared signal patterns — so the two-point discipline is held by this skill and its callers; the classifier itself only judges the text it is handed.

## Signals

YES signals, each with why the training-data answer can't be trusted:

- **Proper-noun library/SDK** (`Next.js`, `Prisma`, `boto3`) — library APIs age fast.
- **Vendor API** (`Stripe webhook`, `Cloudflare Worker`, `Auth0 rule`) — SaaS surfaces evolve outside any library's docs.
- **Version-shaped token** (`Next.js 14`, `>=1.55`, `v4`) — version-conditioned APIs change.
- **Installed-version lookup** ("which X are we on") — the lockfile is ground truth; check, don't guess.
- **Security-sensitive verb** (`auth`, `crypto`, `payment`, `JWT`, `OAuth`) — wrong here is an expensive incident.
- **Security advisory query** (`CVE`, `deprecation notice`, `EOL date`) — needs an authoritative current source.
- **Architectural signal** (`migrate to X`, `set up X`, `schema`, `config syntax`) — patterns shift even when the framework is stable.
- **Explicit user invocation** (`/llm-orchestrator:research`) — asked is answered.

Default-skip everything without an external API surface: pure logic and algorithms, established patterns, fully-specified diffs, single-file edits, mechanical refactors. At `standard` aggressiveness a library mention alone is not enough — it needs a second signal (version, security, or architectural); security alone *is* enough. Tune per project with `/llm-orchestrator:remember research_aggressiveness: low|standard|high` — read on every invocation; levels and the stakes ladder are in [`STRATEGY.md`](./STRATEGY.md).

## The contract

Emit a single `Status:` block. It is internal plumbing — the controller records it and hands it to research dispatch; never print it to the user.

```
Status: RESEARCH_NEEDED
Trigger point: A | B
Libraries: <names, comma-separated>
Versions: <pinned tokens or "unspecified">
Stakes: low | medium | high
Aggressiveness applied: low | standard | high
Triggers matched:
- <signal class>: <quoted phrase from input>
Reason: <one line>
```

```
Status: RESEARCH_SKIP
Reason: <one line — which NO signal applied, or which YES signals were absent>
```

The NEEDED block covers four of the eight fields `orch-researcher` requires; build the rest of the envelope from `templates/researcher-prompt.md` — the agent returns `BLOCKED` on a missing field.

When research runs, the brief lands on one of four outcomes the controller routes on literally:

- **`VERIFIED`** — docs confirm the approach is current; citations attached; proceed unchanged.
- **`COULDN'T_VERIFY`** — no docs reachable; proceed with confidence downgraded, annotated "verified against training only".
- **`NOT_APPLICABLE`** — the question's premise doesn't hold in this repo; nothing to verify.
- **`CONTRADICTED`** — the approach is deprecated, renamed, removed, or wrong for the target version. The brief states what was assumed, what the docs say (citation + retrieval date), the recommended revision, and Critical/Important severity. This halts `writing-plans` — the spec is revised first. It is where the feature earns its keep; demoting it to a soft warning removes the only reason the gate exists.

## Talking to the user

On `RESEARCH_NEEDED`, surface two plain lines — that research is happening and what's being verified (plus an MCP nudge if one applies per [`STRATEGY.md`](./STRATEGY.md)) — never the Status block:

> Found: research needed (expo-sqlite). Verifying the installed version and whether an in-flight write can be cancelled.

On `RESEARCH_SKIP`, say nothing; announcing an automatic non-event is noise. The user can interrupt with `skip research`: acknowledge in one line, flag the staleness tradeoff, log the override once under `## Notes`, and honor later overrides without argument.

## Examples

The curated input→outcome table lives in [`EXAMPLES.md`](./EXAMPLES.md), as documentation for a human reader. It is **not** wired to the test: `tests/test-research-classifier.sh` hardcodes its cases and never opens `EXAMPLES.md`, so editing the table alone changes nothing and fails nothing. When a heuristic or example changes, update this file, `EXAMPLES.md`, and the test together — otherwise they drift silently.
