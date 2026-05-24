# Research brief — <one-line topic>

Date: YYYY-MM-DD
Outcome: VERIFIED | COULDN'T_VERIFY | CONTRADICTED | NOT_APPLICABLE
Trigger point: A (pre-spec) | B (pre-plan)
Stakes: low | medium | high
Libraries: <comma-separated with versions>
Brief by: orch-researcher (1 researcher) | orch-researcher × 3 (parallel high-stakes)

---

## Summary

Three to five bullets. The human reads this first. If the outcome is `CONTRADICTED`, the summary leads with the contradiction and the recommended revision — no preamble.

For **VERIFIED**:
- <one line: what was checked, against what version>
- <one line: noteworthy findings — e.g., "Edge Runtime is now default for middleware">
- <one line: how confident you are>

For **COULDN'T_VERIFY**:
- <one line: what was attempted>
- <one line: why it failed (no MCP, fetch 401, library not indexed)>
- <one line: what proceeds on training knowledge>

For **CONTRADICTED** (the trust-building moment — write this carefully):
- ⚠ Spec assumes: <one-line restatement>
- ⚠ Docs say (<library>@<version>): <one-line correction with version pin>
- Recommended revision: <one line — the API/pattern to use instead>
- Severity: Critical (the planned API no longer exists) | Important (deprecated, still works)

For **NOT_APPLICABLE** (the premise of the question doesn't hold in this repo):
- Premise: <one line — what the question assumed (e.g., "the project uses React")>
- Reality: <one line — what was actually found in the repo (e.g., "no package.json present — this is a shell+markdown plugin, no React")>
- Recommended next step: <one line — what the user might have meant, or which repo to point the researcher at>

---

## What was verified

For each API surface, library, or pattern checked:

### `<library>@<version>` — `<API surface or pattern>`

- Approach planned: `<one-line description from the spec or task>`
- Docs say *(SOURCES axis)* OR Filesystem says *(LOCAL_STATE axis)*: `<one-line of what the authoritative source actually reports>`
- Status: ✓ matches | ⚠ differs | ✗ contradicted

Citations (one form per axis — mix freely when the block spans both):
- <URL> (retrieved 2026-05-24) — for SOURCES findings
- <local-path-or-command> (filesystem, 2026-05-24) — for LOCAL_STATE findings

(Repeat one block per verification question. Questions on the SOURCES axis answer "what should be"; questions on the LOCAL_STATE axis answer "what is" — see the orch-researcher authority hierarchy for routing rules.)

---

## Recommended revision (only for CONTRADICTED)

If outcome is CONTRADICTED, this section is mandatory. It must be specific enough that the user can copy-paste it into the spec.

**Before** (what the spec assumes):
```
<exact text or pseudocode from the spec's Approach>
```

**After** (what current docs support):
```
<the corrected version, ready to drop into the spec>
```

**Why** (one paragraph): explanation of the change, with the version pin where it took effect.

**Severity**: Critical | Important. Critical means the spec's API doesn't exist or doesn't behave as expected at the target version — the plan will fail at build/run. Important means the spec is deprecated but functional — it'll work, but the team is shipping code with a known sunset date.

---

## Premise vs reality (only for NOT_APPLICABLE)

If outcome is NOT_APPLICABLE, this section is mandatory. The user should see in one glance why their question didn't apply to this codebase.

**Premise** (what the question assumed):
```
<one-line restatement of the implicit assumption, e.g. "the project depends on React">
```

**Reality** (what was actually found):
```
<one-line description of the disproving evidence, e.g. "no package.json in repo root; this is a shell+markdown plugin with no JavaScript runtime">
```

**Evidence** (what command/lookup disproved the premise):
- <command or lookup>: <result> (this is your single citation for NOT_APPLICABLE)

**Recommended next step** (one line): the most likely thing the user actually meant, or which project they should point the researcher at instead.

**This section is NOT for soft-pedaling.** If you attempted real verification (cited upstream sources, recorded API findings, drafted recommended revisions), the outcome is CONTRADICTED or COULDN'T_VERIFY — not NOT_APPLICABLE. Use this section only when a single cheap lookup (a filesystem read, a grep) disproves the question's premise outright.

---

## Notes (lower-confidence observations)

Things the docs hint at but you're <80% confident about. Style preferences. Minor performance considerations. From-training claims you couldn't verify but are worth flagging. These do NOT change the outcome — they live separately so the user can scan them or skip them.

- <note> (source: <URL or "from training, not verified">)

---

## Sources

Every URL referenced above, deduplicated, with retrieval date:

- <URL> (retrieved 2026-05-24)
- <URL> (retrieved 2026-05-24)
- <local-doc-path> (read 2026-05-24)

---

## Cache writes

For each library where docs were fetched fresh (not from cache):

- `<library-slug>.md` → `~/.llm-orchestrator/research/cache/<project-hash>/`

(Future gates will read these. 30-day TTL by default; override by editing `cache_ttl_days:` in the cache file's frontmatter.)
