---
name: research-classifier
description: Use when about to invoke brainstorming or writing-plans, before any spec or plan is committed. Decides whether the task needs a research-before-build gate (verify API surfaces against current docs) or can proceed on the team's parametric knowledge.
---

# Research classifier

The cheapest, most-aggressive-to-skip gate before research fires. Bias toward SKIP. Over-triggering kills UX; under-triggering makes the feature invisible. Default outcome on most tasks is `RESEARCH_SKIP`.

## When to invoke

Two fixed trigger points only — never every turn:

- **Trigger A — pre-spec**: between `brainstorming` step 1 (read the room) and step 2 (clarifying questions). Inputs: the user's raw task text.
- **Trigger B — pre-plan**: at `writing-plans` step 0, before any plan file is written. Inputs: the spec's `## Approach` section.

Do not invoke for arbitrary user messages, for `/llm-orchestrator:debug`, `/verify`, `/finish`, or for any non-design conversation. The hook layer enforces this — the classifier itself only checks signals against the input it receives.

## Signal heuristics

### YES signals (raise the trigger flag)

| Class                       | Example                                                                                       | Why                                                                |
|-----------------------------|-----------------------------------------------------------------------------------------------|---------------------------------------------------------------------|
| Proper-noun library/SDK     | `Next.js`, `Prisma`, `tailwindcss`, `boto3`                                                   | Training data is library-specific and ages fast                    |
| Vendor API (SaaS platform)  | `Stripe webhook`, `Cloudflare Worker`, `Vercel KV`, `Auth0 rule`, `Supabase row policy`       | Vendor APIs evolve outside the library docs the model trained on   |
| Version-shaped token        | `Next.js 14`, `>=1.55`, `v4`, `Tailwind v4`                                                   | Version-conditioned APIs change                                    |
| Installed-version lookup    | "what version of X is installed", "which X are we on", "current X version"                    | Lockfile is ground truth — check, don't guess                      |
| Security-sensitive verb     | `auth`, `crypto`, `payment`, `secret`, `JWT`, `OAuth`                                         | Wrong here = expensive incident                                    |
| Security advisory query     | `CVE`, `vulnerability`, `security advisory`, `deprecation notice`, `EOL date`                 | The reader needs an authoritative current source, not training data|
| Architectural signal        | `migrate to X`, `replace Y with Z`, `set up X`, `migration`, `schema`, `config syntax`        | Patterns shift even when the framework's stable                    |
| Explicit user invocation    | `/llm-orchestrator:research`                                                                  | User asked for it                                                  |

### NO signals (default skip)

| Class                  | Example                                              | Why                                             |
|------------------------|------------------------------------------------------|-------------------------------------------------|
| Pure logic / algorithm | "Write a function that flattens an array"            | No external API surface                         |
| Established pattern    | "Add a test for users.ts:42"                         | Pattern is stable across years                  |
| Fully-specified diff   | "Change line 42 from `foo` to `bar`"                 | Nothing to research                             |
| Single-file edit       | "Fix the typo in README.md"                          | No API surface in scope                         |
| Mechanical refactor    | "Rename `users` to `accounts` everywhere in users.ts"| Type system catches regressions                 |

## Per-project aggressiveness tuning

Read project memory file (`~/.llm-orchestrator/memory/<project-hash>.md`) for a `## Research config` section. Default is `standard` if absent.

| Level     | Triggers on                                                                                      |
|-----------|---------------------------------------------------------------------------------------------------|
| `low`     | Explicit version pins, security keywords, or `/llm-orchestrator:research`. Library mentions alone are not enough. |
| `standard`| (default) Library + (version OR security OR architectural verb). Single library mention with no other signal skips. |
| `high`    | Any library mention, any architectural verb. Single signal is enough.                            |

Set via `/llm-orchestrator:remember research_aggressiveness: high` (or low / standard). The classifier reads on every invocation; no restart needed.

## Stakes ladder (used downstream by research dispatch)

The classifier emits a stakes value the researcher uses to decide depth and parallelism. **Step 1 just records this; step 2 acts on it.**

| Stakes  | Heuristic                                                                                      |
|---------|------------------------------------------------------------------------------------------------|
| `low`   | One library, well-established, no version signal (e.g., `React.useState`, Python stdlib).      |
| `medium`| One library, version-specific or fast-moving (Next.js, Prisma, OpenAI SDK).                    |
| `high`  | Multiple libraries OR security-sensitive OR architectural decision OR explicit user invocation.|

## The contract: what the classifier produces

The classifier emits a single `Status:` block (below). **This block is internal** — the controller records it and hands it to the researcher dispatch. Never print it to the user; the human sees only the one-line acknowledgment in "Working dialogue with the user" below.

### When research should fire

```
Status: RESEARCH_NEEDED
Trigger point: A | B
Libraries: <names>, comma-separated
Versions: <pinned tokens or "unspecified">
Stakes: low | medium | high
Aggressiveness applied: low | standard | high
Triggers matched:
- <signal class>: <quoted phrase from input>
- <...>
Reason: <one line — why this passes the gate>
```

### When research should skip

```
Status: RESEARCH_SKIP
Reason: <one line — which NO signal applied, or which YES signals were absent>
```

### Contract for downstream research (step 2/3 will honor this)

When research runs, the brief MUST report one of three first-class outcomes:

- **`VERIFIED`** — docs confirm the planned approach is current and correct. Citations attached; spec/plan proceeds unchanged.
- **`COULDN'T_VERIFY`** — no docs reachable for the libraries in scope. Downgrade confidence; spec/plan annotates "verified against training only".
- **`CONTRADICTED`** — **first-class outcome**. Docs say the planned approach is deprecated, renamed, removed, or wrong for the target version. The brief must include:
  - what the spec assumed
  - what the docs actually say (with citation + retrieval date)
  - the recommended revision
  - whether the contradiction blocks (Critical) or warns (Important)

A `CONTRADICTED` outcome means the controller must not let `writing-plans` produce the plan as-is. The spec is revised to the docs' recommendation before proceeding. This is the case where this feature earns its keep — the moment the team catches itself before shipping deprecated code.

## Capability survey + MCP nudge (runs only when RESEARCH_NEEDED)

Once `RESEARCH_NEEDED` is the verdict, the classifier checks what research tools are connected before any researcher dispatch. The survey looks for these families (Context7 is **one** option among several — never the reflexive default):

| Family                            | What it's best for                                                | How to detect (tool-name patterns)                                |
|-----------------------------------|--------------------------------------------------------------------|--------------------------------------------------------------------|
| Vendor-specific MCPs              | Authoritative answers for that vendor's API                       | `mcp__stripe*`, `mcp__cloudflare*`, `mcp__vercel*`, `mcp__aws-*`, `mcp__supabase*`, etc. |
| Doc-aggregator MCPs               | Version-pinned library/framework docs                             | `mcp__*context7*`, `mcp__*deepwiki*`                              |
| GitHub MCP                        | Changelogs, releases, closed issues, security advisories          | `mcp__github*` with `releases`/`advisories`/`issues` tools         |
| Filesystem MCP                    | "What's actually installed" — lockfile ground truth                | `mcp__filesystem*`, or built-in `Read`/`Grep` on package.json etc. |
| Web search MCPs                   | Open-ended queries, "what's new in X"                              | `mcp__brave*`, `mcp__exa*`, `mcp__tavily*`, `mcp__perplexity*`     |
| Built-in `WebFetch` + `WebSearch` | Always available; fallback when no specialized MCP fits           | Always assume yes                                                  |
| `local-docs`                      | Project's own `docs/`, `README*`, vendored `node_modules/.../README.md` | Always available; cheap; always check                          |

### Two epistemic axes the researcher routes onto

Verification questions split into two kinds, and the right tool depends on which kind:

- **SOURCES axis — "what should be."** Current API surface, recommended pattern, deprecation status, vendor expectations, advisory data, changelog deltas. The MCP families in the table above are authoritative on this axis; nudge eligibility is decided by source-authority gaps here.
- **LOCAL_STATE axis — "what is."** What's installed, what's in this project's config, what does an on-disk artifact actually contain, what local conventions are in use. The authoritative tools on this axis are `Read`, `Grep`, and `Bash` — no MCP is more authoritative than the local disk for state questions. **The right behavior on the LOCAL_STATE axis is silent: no nudge, no parenthetical, just run the lookup and report the answer in the brief.**

A single task may span both axes (a `/cost` command, for example, needs vendor pricing on SOURCES and JSONL schema on LOCAL_STATE). The classifier doesn't pick the axis — that's per-question routing inside the orch-researcher. The classifier just records that research is needed; the agent's authority hierarchy handles axis selection.

### Picking the MCP to suggest (task-aware, single best signal)

The nudge surfaces only if a **gap** exists: the task's most-significant signal has a *more authoritative* MCP available than what's currently connected, AND project memory hasn't recently declined that MCP. Map task signals → MCP family:

| Most-significant task signal              | MCP to suggest (if not connected)                          |
|-------------------------------------------|-------------------------------------------------------------|
| Vendor API (Stripe, Cloudflare, Vercel…)  | The vendor's own MCP (`stripe-mcp`, `cloudflare-mcp`, etc.) |
| Library / framework API                   | Context7 (most coverage today), DeepWiki as alternative     |
| Security advisory / CVE query             | GitHub MCP (advisories endpoint)                            |
| "What version is installed"               | Filesystem MCP (or built-in Read suffices — no nudge)       |
| Changelog / "what changed between A and B"| GitHub MCP (releases endpoint)                              |
| Open-ended technical query                | A web-search MCP (Brave / Exa / Tavily / Perplexity)        |

**Multi-signal tasks** (e.g., "wire Stripe Checkout via the Next.js 14 app router"): pick the SINGLE most-authoritative-gap. Vendor MCP for the vendor's API wins over library-docs MCP for the library — Stripe's own MCP is more authoritative for Stripe than any third-party aggregator. The nudge mentions ONE MCP, never a list. If the connected toolchain already covers the most-authoritative signal, no nudge — even if other signals could be slightly better served.

### Nudge wording (hard rules — do not soften)

- One sentence, parenthetical, ends with a declarative close like "Continuing." or "Proceeding either way." — the user does not have to answer.
- Names the **specific signal** that triggered it (the library, the vendor, the changelog, the CVE component) — not a generic "you might want docs."
- Names the **specific MCP** by its conventional name (`Stripe MCP`, `Context7`, `GitHub MCP`) — without selling it.
- Optional: a single short link only if it fits the natural flow.
- **Never asks a question.** The nudge is information, not a prompt.
- If the user says "skip mcp", "don't suggest again", or `/forget mcp-nudge`, log to project memory:
  ```
  ## Research config
  - declined_mcp: stripe-mcp for stripe-api (2026-05-24)
  - declined_mcp: context7 for library-docs (2026-05-24)
  ```
  Each entry records the MCP, what signal it was suggested for, and when. Do not re-nudge that (MCP, signal) pair for 12 months.
- If memory already contains a recent matching `declined_mcp` entry, skip the nudge entirely.

### Bad shapes (do not emit)

- "💡 Tip: connect Context7 MCP for…" — feature-ad register.
- "Notice: Stripe MCP is not connected. Would you like to enable it?" — popup register.
- "I recommend you install GitHub MCP because…" — pitch register.
- "**Install/connect the GitHub MCP server. For CVE/advisory questions this is the authoritative source — structured GHSA + CVE lookups beat scraping the advisories UI...**" — imperative register, separate paragraph, reads like a feature ad even though the technical content is correct. **The parenthetical-embedded form is non-negotiable; if you find yourself writing a paragraph, you're nudging wrong.**

### Good shapes (write something like one of these — one worked example per MCP family)

**Library/framework docs (Context7):**
> "(Researching Prisma schema patterns via WebFetch. Context7 would give version-pinned Prisma docs if you want to connect it.)"

**Vendor API (vendor's own MCP):**
> "(Verifying Stripe Checkout v15 against Stripe's web docs. The Stripe MCP, if connected, would give authoritative API answers directly — continuing.)"

**Security advisory (GitHub MCP — advisories endpoint):**
> "(Checking React 19 against the GitHub Advisory Database via WebSearch. GitHub MCP, if connected, would give structured GHSA lookups by version range — continuing.)"

**Changelog / release notes (GitHub MCP — releases endpoint):**
> "(Comparing next.js 14 → 15 via WebFetch on the changelog page. GitHub MCP would surface releases programmatically — continuing.)"

**Open-ended technical query (web-search MCP — Brave / Exa / Tavily):**
> "(Looking up best-practice 2026 patterns for X via WebSearch. A web-search MCP like Brave or Exa would return ranked technical results faster — proceeding either way.)"

**Installed-version lookup (no nudge fired — filesystem ground truth is sufficient):**
> The right move is to NOT nudge. Read `package.json` / `pyproject.toml` / lockfile directly. No MCP suggestion is more authoritative than the lockfile itself. Example of correct silent behavior:
>
> *Agent does not surface a parenthetical for "what version of X is installed" — instead it just runs the lockfile read and reports the answer in the brief.* If the brief notes "no lockfile found and no system version reachable," that's a `COULDN'T_VERIFY` outcome, still no MCP nudge.

The nudge surfaces inline with the announcement, not as a separate message. **Five worked examples + one "no nudge fired" template** — if the case at hand doesn't fit one of these six shapes, default to silent (no nudge) rather than improvising into imperative register.

## Examples (curated — used by the smoke test)

These are the inputs `tests/test-research-classifier.sh` runs to verify the rules stay consistent.

| Input                                                              | Expected     | Why                                                            |
|--------------------------------------------------------------------|--------------|-----------------------------------------------------------------|
| "Add a function that returns the current ISO timestamp"            | `SKIP`       | Pure logic. No library surface.                                |
| "Fix the typo in README.md"                                        | `SKIP`       | Mechanical edit.                                                |
| "Rename `users` to `accounts` throughout users.ts"                 | `SKIP`       | Refactor; type system catches errors.                          |
| "Add a test for users.ts:42"                                       | `SKIP`       | Established pattern.                                            |
| "Add OAuth login with Auth0"                                       | `NEEDED`     | Library + security verb.                                       |
| "Migrate the test suite from Mocha to Vitest"                      | `NEEDED`     | Library transition; version-shifted APIs.                      |
| "Set up Next.js 14 middleware for tenant routing"                  | `NEEDED`     | Version + framework + architectural verb.                      |
| "Add a Prisma migration for the user_policy table"                 | `NEEDED`     | Library; migrations are version-sensitive.                      |
| "Implement JWT token refresh"                                      | `NEEDED`     | Security verb.                                                  |
| "Reduce the cyclomatic complexity of users.ts:checkAccess"         | `SKIP`       | Pure refactor; no API surface.                                  |
| "Add a debounce util in src/lib/"                                  | `SKIP`       | Pure logic.                                                     |
| "Wire Stripe Checkout with the v15 SDK"                            | `NEEDED`     | Library + version + payment (security-sensitive).               |

These examples carry through to the smoke test as ground truth. If a heuristic change moves any of these, the test fails — surface it before merge.

## Working dialogue with the user

When `RESEARCH_NEEDED` fires, do not print the internal block (Trigger point, Libraries, Versions, Stakes, Aggressiveness, Triggers matched, Reason) — that is plumbing, useless to a human. Surface only two plain lines: that research is happening, and what you're verifying (plus the MCP nudge if any).

> Found: research needed (expo-sqlite). Verifying the installed version and whether an in-flight write can be cancelled. (Context7 covers the docs.)

No stakes, no trigger lists, no "aggressiveness applied." The user can interrupt with `skip research`. When they do, acknowledge it in one line and flag the tradeoff — then log the override once under `## Notes` and don't refuse later overrides:

> Skipping research per your call — proceeding on training knowledge for expo-sqlite (may be stale).

When the classifier itself returns `RESEARCH_SKIP` (no research needed), show nothing — that's an automatic decision, not a user action; announcing it is noise. Acknowledge only the user's explicit `skip research`.

## Anti-patterns

- Running the classifier on every user message. It runs **only** at Trigger A or Trigger B.
- Treating a library mention as automatic NEEDED. Standard aggressiveness requires a second signal.
- Treating `CONTRADICTED` as a soft warning. It is first-class — the plan must be revised.
- Over-explaining the SKIP decision. One bullet of reason is enough.
- Dumping the internal Status block to the user. Surface one plain line — not the Trigger/Stakes/Aggressiveness/Reason fields.
- Hardcoding the signal lists in code without keeping the Examples table in sync. The smoke test reads this skill's table; drift breaks both.
- Writing the MCP nudge as a question. It is an observation, not a popup.
- Re-nudging within 12 months when memory shows a matching `declined_mcp:` entry. Read memory before nudging.
- Nudging more than once per task. The nudge surfaces only when the most-authoritative-gap is a connected MCP the user hasn't declined.
- Defaulting to Context7 for every library mention. The right MCP is task-shape dependent — vendor MCPs for vendor APIs, GitHub MCP for changelogs/advisories, Context7 for general library docs, filesystem read for "what's installed."
- Nudging two MCPs in the same parenthetical. Pick one — the most authoritative gap.

## Output shape

The internal block is the one under "The contract" above — recorded by the controller, handed to the researcher, never shown to the user. What the **user** sees is one plain line:

> Found: research needed (expo-sqlite). Verifying the installed version + whether a write can be cancelled. (Context7 covers the docs.)
