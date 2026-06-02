# Research classifier — strategy reference

Detail behind [`SKILL.md`](./SKILL.md): aggressiveness tuning, the stakes ladder, the capability survey, and the MCP-nudge rules. Read this when a task has reached `RESEARCH_NEEDED` and you're deciding depth and whether to nudge.

## Per-project aggressiveness tuning

Read the project memory file (`~/.llm-orchestrator/memory/<project-hash>.md`) for a `## Research config` section. Default is `standard` if absent.

| Level     | Triggers on                                                                                                       |
|-----------|------------------------------------------------------------------------------------------------------------------|
| `low`     | Explicit version pins, security keywords, or `/llm-orchestrator:research`. Library mentions alone are not enough. |
| `standard`| (default) Library + (version OR security OR architectural verb). A single library mention with no other signal skips. |
| `high`    | Any library mention, any architectural verb. A single signal is enough.                                          |

Set via `/llm-orchestrator:remember research_aggressiveness: high` (or `low` / `standard`). The classifier reads it on every invocation; no restart needed.

## Stakes ladder (used downstream by research dispatch)

The classifier emits a stakes value the researcher uses to decide depth and parallelism. Step 1 records it; step 2 acts on it.

| Stakes  | Heuristic                                                                                       |
|---------|-------------------------------------------------------------------------------------------------|
| `low`   | One library, well-established, no version signal (e.g., `React.useState`, Python stdlib).       |
| `medium`| One library, version-specific or fast-moving (Next.js, Prisma, OpenAI SDK).                     |
| `high`  | Multiple libraries OR security-sensitive OR architectural decision OR explicit user invocation. |

## Capability survey (runs only when RESEARCH_NEEDED)

Once `RESEARCH_NEEDED` is the verdict, check what research tools are connected before any dispatch. The survey looks for these families — a doc-aggregator is **one** option among several, never the reflexive default:

| Family                            | Best for                                                  | Detect (tool-name patterns)                                       |
|-----------------------------------|-----------------------------------------------------------|-------------------------------------------------------------------|
| Vendor-specific MCPs              | Authoritative answers for that vendor's API               | `mcp__stripe*`, `mcp__cloudflare*`, `mcp__vercel*`, `mcp__supabase*` |
| Doc-aggregator MCPs               | Version-pinned library/framework docs                     | `mcp__*context7*`, `mcp__*deepwiki*`                               |
| GitHub MCP                        | Changelogs, releases, closed issues, security advisories  | `mcp__github*` with `releases`/`advisories`/`issues` tools        |
| Filesystem MCP                    | "What's actually installed" — lockfile ground truth       | `mcp__filesystem*`, or built-in `Read`/`Grep` on package.json     |
| Web search MCPs                   | Open-ended queries, "what's new in X"                     | `mcp__brave*`, `mcp__exa*`, `mcp__tavily*`, `mcp__perplexity*`     |
| Built-in `WebFetch` + `WebSearch` | Always available; fallback when no specialized MCP fits   | Always assume yes                                                  |
| `local-docs`                      | Project's own `docs/`, `README*`, vendored READMEs        | Always available; cheap; always check                             |

### Two epistemic axes the researcher routes onto

- **SOURCES axis — "what should be."** Current API surface, recommended pattern, deprecation status, advisory data, changelog deltas. The MCP families above are authoritative here; nudge eligibility is decided by source-authority gaps on this axis.
- **LOCAL_STATE axis — "what is."** What's installed, what's in this project's config, what an on-disk artifact contains. The authoritative tools are `Read`, `Grep`, `Bash` — no MCP beats the local disk for state questions. The right behavior here is silent: no nudge, just run the lookup and report the answer.

A single task may span both axes (a `/cost` command needs vendor pricing on SOURCES and JSONL schema on LOCAL_STATE). The classifier doesn't pick the axis — that's per-question routing inside the research step. The classifier just records that research is needed.

## The MCP nudge

The nudge surfaces only if a **gap** exists: the task's most-significant signal has a *more authoritative* MCP available than what's connected, AND project memory hasn't recently declined that MCP.

| Most-significant task signal               | MCP to suggest (if not connected)                          |
|--------------------------------------------|-------------------------------------------------------------|
| Vendor API (Stripe, Cloudflare, Vercel…)   | The vendor's own MCP (`stripe-mcp`, `cloudflare-mcp`, etc.) |
| Library / framework API                    | Context7 (most coverage today), DeepWiki as alternative     |
| Security advisory / CVE query              | GitHub MCP (advisories endpoint)                            |
| "What version is installed"                | Filesystem MCP (or built-in Read suffices — no nudge)       |
| Changelog / "what changed between A and B" | GitHub MCP (releases endpoint)                              |
| Open-ended technical query                 | A web-search MCP (Brave / Exa / Tavily / Perplexity)        |

**Multi-signal tasks** (e.g., "wire Stripe Checkout via the Next.js 14 app router"): pick the SINGLE most-authoritative gap. The vendor's own MCP wins over a third-party aggregator for that vendor's API. The nudge mentions ONE MCP, never a list. If the connected toolchain already covers the most-authoritative signal, no nudge.

### Nudge wording

- One sentence, parenthetical, ending in a declarative close ("Continuing.", "Proceeding either way.") — the user does not have to answer.
- Names the **specific signal** that triggered it (the library, vendor, changelog, CVE component) — not a generic "you might want docs."
- Names the **specific MCP** by its conventional name (`Stripe MCP`, `Context7`, `GitHub MCP`) without selling it.
- Never asks a question. The nudge is information, not a prompt.
- If the user says "skip mcp", "don't suggest again", or `/forget mcp-nudge`, log to project memory and don't re-nudge that (MCP, signal) pair for 12 months:
  ```
  ## Research config
  - declined_mcp: stripe-mcp for stripe-api (2026-05-24)
  ```
- If memory already holds a recent matching `declined_mcp` entry, skip the nudge entirely.

### Bad shapes (do not emit)

- "💡 Tip: connect Context7 MCP for…" — feature-ad register.
- "Notice: Stripe MCP is not connected. Would you like to enable it?" — popup register.
- "I recommend you install GitHub MCP because…" — pitch register.
- A separate imperative paragraph selling an MCP — even if the technical content is correct. If you're writing a paragraph, you're nudging wrong; the parenthetical-embedded form is the only acceptable one.

### Good shapes (one worked example per family)

- **Library/framework docs (Context7):** "(Researching Prisma schema patterns via WebFetch. Context7 would give version-pinned Prisma docs if you want to connect it.)"
- **Vendor API:** "(Verifying Stripe Checkout v15 against Stripe's web docs. The Stripe MCP, if connected, would give authoritative API answers directly — continuing.)"
- **Security advisory (GitHub MCP):** "(Checking React 19 against the GitHub Advisory Database via WebSearch. GitHub MCP would give structured GHSA lookups by version range — continuing.)"
- **Changelog (GitHub MCP):** "(Comparing next.js 14 → 15 via WebFetch on the changelog page. GitHub MCP would surface releases programmatically — continuing.)"
- **Open-ended query (web-search MCP):** "(Looking up best-practice 2026 patterns for X via WebSearch. A web-search MCP like Brave or Exa would return ranked results faster — proceeding either way.)"
- **Installed-version lookup (no nudge):** read `package.json` / lockfile directly and report the answer. No MCP is more authoritative than the lockfile. If none is reachable, that's `COULDN'T_VERIFY` — still no nudge.

If the case at hand doesn't fit one of these shapes, default to silent rather than improvising into imperative register.
