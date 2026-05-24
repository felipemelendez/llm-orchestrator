# Research brief: `/llm-orchestrator:cost` command

Date: 2026-05-24
Outcome: VERIFIED (with implementation-altering caveats)
Trigger point: A (pre-spec)
Stakes: medium
Libraries: Claude Code (CLI runtime), JSONL transcript format
Brief by: orch-researcher (1 researcher)

---

## Summary

- ✓ Verified Claude Code stores per-session JSONL at `~/.claude/projects/<sanitized-cwd>/<session-uuid>.jsonl` — filesystem-confirmed against this project's actual transcript directory
- ✓ Verified schema includes `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}` plus `message.model` — parsed from a real assistant line
- ⚠ **Found three implementation-altering caveats** that a naive build would miss (see below)
- Sources: 4 distinct (filesystem read, Anthropic pricing page, Claude Code slash-commands docs, Claude Code hooks docs)

## What was verified

### Q1 — Transcript file location

- Approach planned: parse Claude Code's JSONL transcripts
- Filesystem says: `~/.claude/projects/<sanitized-cwd>/<session-uuid>.jsonl`. Directory name is absolute `cwd` with `/` replaced by `-`. Filename stem = `sessionId` field on every line.
- Status: ✓ matches

Citations:
- `/Users/felipemelendez/.claude/projects/-Users-felipemelendez-LLM-Orchestrator/` (filesystem inspection, 2026-05-24)

### Q2 — JSONL schema

- Approach planned: extract `input_tokens`, `output_tokens`, cache token fields, `model` per line
- Schema actually says: each line has `type` discriminator (only `type: "assistant"` carries usage); `message.usage` contains the four token fields the task names PLUS `cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}` (the cache write split); `message.model` at `message.model`, not top-level; `server_tool_use.web_search_requests` exists for web-search surcharge accounting.
- Status: ⚠ differs in implementation-relevant ways — `cache_creation_input_tokens` is the **sum** of 5m + 1h cache writes; those have **different rates**. Naive use of the sum would mis-price.

Citations:
- Direct parse of `d9fb944c-c919-4df5-af9f-d5cbfb00a546.jsonl` (filesystem, 2026-05-24)

### Q3 — Model pricing (per million tokens, USD, standard tier)

| Model | Input | 5m cache write | 1h cache write | Cache read | Output |
|---|---|---|---|---|---|
| Claude Opus 4.7 | $5 | $6.25 | $10 | $0.50 | $25 |
| Claude Opus 4.6 | $5 | $6.25 | $10 | $0.50 | $25 |
| Claude Opus 4.5 | $5 | $6.25 | $10 | $0.50 | $25 |
| Claude Opus 4.1 | $15 | $18.75 | $30 | $1.50 | $75 |
| Claude Sonnet 4.6 | $3 | $3.75 | $6 | $0.30 | $15 |
| Claude Haiku 4.5 | $1 | $1.25 | $2 | $0.10 | $5 |

Multiplier rule: 5m write = 1.25× input, 1h write = 2× input, cache read = 0.1× input.

**Web search surcharge:** $10 per 1,000 `server_tool_use.web_search_requests`, in addition to tokens. Naive cost trackers miss this.

**Opus 4.7 tokenizer change:** the docs note Opus 4.7 may use up to 35% more tokens for the same text vs prior models — relevant when comparing sessions across model upgrades.

Citations:
- https://platform.claude.com/docs/en/about-claude/pricing (retrieved 2026-05-24)

### Q4 — Session ID exposure

- Approach planned: have bare `/llm-orchestrator:cost` find the current transcript
- Docs say: there is **no OS env var** named `CLAUDE_SESSION_ID`. Two clean access paths exist instead:
  1. Inside a SKILL.md / slash-command file: use the `${CLAUDE_SESSION_ID}` string substitution (rendered into the prompt before Claude sees it, NOT exported to the subprocess environment).
  2. Inside a hook script: stdin JSON contains `session_id` AND `transcript_path` — `transcript_path` removes the need to reconstruct the sanitized-cwd path yourself.
- Status: ⚠ differs from likely default assumption — the implementation needs to commit to "SKILL with substitution" or "hook with transcript_path"; an OS-env-var approach doesn't exist.

Citations:
- https://code.claude.com/docs/en/slash-commands (retrieved 2026-05-24)
- https://code.claude.com/docs/en/hooks (retrieved 2026-05-24)
- https://code.claude.com/docs/en/settings (retrieved 2026-05-24, confirms no env var)

---

## Implementation implications (spec author should incorporate)

1. **Use `transcript_path` (hook stdin) or `${CLAUDE_SESSION_ID}` (SKILL substitution)** — do NOT design around an OS env var.
2. **Iterate JSONL, filter `type == "assistant"`** — most lines carry no cost.
3. **Split cache writes by `cache_creation.ephemeral_5m_input_tokens` vs `ephemeral_1h_input_tokens`.** Pricing is 1.25× vs 2× base input. `cache_creation_input_tokens` (the sum) is NOT directly priceable.
4. **Add `web_search_requests × $0.01`** from `server_tool_use`. Document the exclusion of other server-tool surcharges.
5. **For `--all`:** glob `~/.claude/projects/<sanitized-cwd>/*.jsonl`. Sanitized-cwd is `$PWD` with `/` → `-`.
6. **Pricing table should be data, not code.** Pin with a "verified YYYY-MM-DD" comment + link to the pricing page. Anthropic adds model rows over time.
7. **Tolerate unknown model strings** — emit a warning, don't crash. Useful for forward-compat with future model releases.

---

## Sources

- `/Users/felipemelendez/.claude/projects/-Users-felipemelendez-LLM-Orchestrator/` (filesystem, 2026-05-24)
- https://platform.claude.com/docs/en/about-claude/pricing (retrieved 2026-05-24)
- https://code.claude.com/docs/en/slash-commands (retrieved 2026-05-24)
- https://code.claude.com/docs/en/hooks (retrieved 2026-05-24)
- https://code.claude.com/docs/en/settings (retrieved 2026-05-24, negative-result citation)

---

## Meta — what the gate caught

A naive `/cost` implementation built from training knowledge would have:
1. Looked for an OS env var for session ID (doesn't exist)
2. Priced `cache_creation_input_tokens` as a single bucket (it's a sum of two different rates)
3. Missed the $10/1k web-search surcharge entirely
4. Hardcoded pricing in source instead of as data

The researcher caught all four before the spec was written. Wall-clock: ~2 minutes. User intervention: zero.

This is the trust-building moment in flesh — small enough to be unglamorous, real enough to save hours of debugging.
