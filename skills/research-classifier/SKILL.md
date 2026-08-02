---
name: research-classifier
description: Use when about to invoke brainstorming or writing-plans, before a spec or plan is committed. Decides whether to verify API surfaces against current docs first.
---

# Research classifier

The cheapest, most-aggressive-to-skip gate before research fires. Bias toward SKIP. Over-triggering kills UX; under-triggering makes the feature invisible. Default outcome on most tasks is `RESEARCH_SKIP`.

Two reference files carry the detail this body points to:
- [`STRATEGY.md`](./STRATEGY.md) — aggressiveness tuning, the stakes ladder, the capability survey, and the MCP-nudge rules.
- [`EXAMPLES.md`](./EXAMPLES.md) — the curated input→outcome table, kept in sync by hand (see Examples).

## When to invoke

Two fixed trigger points only — never every turn:

- **Trigger A — pre-spec**: between `brainstorming` step 1 (read the room) and step 2 (clarifying questions). Input: the user's raw task text.
- **Trigger B — pre-plan**: at `writing-plans` step 0, before any plan file is written. Input: the spec's `## Approach` section.

Don't invoke for arbitrary user messages, for `/llm-orchestrator:debug`, `/llm-orchestrator:verify`, `/llm-orchestrator:finish`, or any non-design conversation. The hook layer enforces this; the classifier itself only checks signals against the input it receives.

## Signal heuristics

### YES signals (raise the trigger flag)

| Class                       | Example                                                                                 | Why                                                                |
|-----------------------------|-----------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| Proper-noun library/SDK     | `Next.js`, `Prisma`, `tailwindcss`, `boto3`                                              | Training data is library-specific and ages fast                    |
| Vendor API (SaaS platform)  | `Stripe webhook`, `Cloudflare Worker`, `Vercel KV`, `Auth0 rule`                         | Vendor APIs evolve outside the library docs the model trained on   |
| Version-shaped token        | `Next.js 14`, `>=1.55`, `v4`, `Tailwind v4`                                              | Version-conditioned APIs change                                    |
| Installed-version lookup    | "what version of X is installed", "which X are we on"                                    | Lockfile is ground truth — check, don't guess                      |
| Security-sensitive verb     | `auth`, `crypto`, `payment`, `secret`, `JWT`, `OAuth`                                    | Wrong here = expensive incident                                    |
| Security advisory query     | `CVE`, `vulnerability`, `security advisory`, `deprecation notice`, `EOL date`            | The reader needs an authoritative current source, not training data|
| Architectural signal        | `migrate to X`, `replace Y with Z`, `set up X`, `migration`, `schema`, `config syntax`  | Patterns shift even when the framework's stable                    |
| Explicit user invocation    | `/llm-orchestrator:research`                                                             | User asked for it                                                  |

### NO signals (default skip)

| Class                  | Example                                               | Why                              |
|------------------------|-------------------------------------------------------|----------------------------------|
| Pure logic / algorithm | "Write a function that flattens an array"             | No external API surface          |
| Established pattern    | "Add a test for users.ts:42"                          | Pattern is stable across years   |
| Fully-specified diff   | "Change line 42 from `foo` to `bar`"                  | Nothing to research              |
| Single-file edit       | "Fix the typo in README.md"                           | No API surface in scope          |
| Mechanical refactor    | "Rename `users` to `accounts` everywhere in users.ts" | Type system catches regressions  |

Per-project aggressiveness (`low` / `standard` / `high`) tunes how many signals are required; `standard` is the default. Set it with `/llm-orchestrator:remember research_aggressiveness: <level>`. The classifier reads it on every invocation — see [`STRATEGY.md`](./STRATEGY.md) for the levels and the stakes ladder.

## The contract: what the classifier produces

The classifier emits a single `Status:` block. **This block is internal** — the controller records it and hands it to research dispatch. Never print it to the user; the human sees only the one-line acknowledgment under "Working dialogue" below.

When research should fire:

```
Status: RESEARCH_NEEDED
Trigger point: A | B
Libraries: <names>, comma-separated
Versions: <pinned tokens or "unspecified">
Stakes: low | medium | high
Aggressiveness applied: low | standard | high
Triggers matched:
- <signal class>: <quoted phrase from input>
Reason: <one line — why this passes the gate>
```

This covers four of the eight fields `orch-researcher` requires. Build the rest
of the envelope with `templates/researcher-prompt.md` before dispatching — the
agent returns `BLOCKED` on a missing field.

When research should skip:

```
Status: RESEARCH_SKIP
Reason: <one line — which NO signal applied, or which YES signals were absent>
```

When research runs, the brief reports one of four first-class outcomes:

- **`VERIFIED`** — docs confirm the approach is current. Citations attached; spec/plan proceeds unchanged.
- **`COULDN'T_VERIFY`** — no docs reachable. Downgrade confidence; spec/plan annotates "verified against training only".
- **`NOT_APPLICABLE`** — the question's premise doesn't hold in this repo; nothing to verify.
- **`CONTRADICTED`** — docs say the approach is deprecated, renamed, removed, or wrong for the target version. The brief states what the spec assumed, what the docs say (with citation + retrieval date), the recommended revision, and whether it blocks (Critical) or warns (Important). A `CONTRADICTED` outcome means `writing-plans` must not produce the plan as-is — the spec is revised first. This is where the feature earns its keep.

## Working dialogue with the user

When `RESEARCH_NEEDED` fires, don't print the internal block — that's plumbing. Surface two plain lines: that research is happening, and what you're verifying (plus an MCP nudge if one applies, per [`STRATEGY.md`](./STRATEGY.md)).

> Found: research needed (expo-sqlite). Verifying the installed version and whether an in-flight write can be cancelled. (Context7 covers the docs.)

The user can interrupt with `skip research`. Acknowledge in one line, flag the tradeoff, log the override once under `## Notes`, and don't refuse later overrides:

> Skipping research per your call — proceeding on training knowledge for expo-sqlite (may be stale).

When the classifier returns `RESEARCH_SKIP`, show nothing — it's an automatic decision, and announcing it is noise.

## Examples

The curated input→outcome table lives in [`EXAMPLES.md`](./EXAMPLES.md), as documentation for a human reader.

It is **not** wired to the test. `tests/test-research-classifier.sh` hardcodes its cases and never opens `EXAMPLES.md`, so editing that file alone changes nothing and fails nothing. Keep the two in sync by hand, and when you add a case that matters, add it to the test as well.

## Anti-patterns

- Running the classifier on every user message. It runs **only** at Trigger A or Trigger B.
- Treating a library mention as automatic NEEDED. Standard aggressiveness requires a second signal.
- Treating `CONTRADICTED` as a soft warning. It is first-class — the plan must be revised.
- Over-explaining the SKIP decision, or dumping the internal Status block to the user. One plain line is enough.
- Changing a heuristic without keeping [`EXAMPLES.md`](./EXAMPLES.md) in sync. The smoke test reads those cases; drift breaks the build.
