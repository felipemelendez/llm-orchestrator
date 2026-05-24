# Real briefs from the research gate

This directory holds **real, unedited research briefs** produced by `orch-researcher` during live testing. Each file is a snapshot of the gate catching itself — a verification that prevented a stale-knowledge bug from shipping.

These exist for two reasons:

1. **Future README work.** When we eventually pitch the research gate, abstract claims ("verifies before committing") are weaker than a real catch the system actually made. The briefs in this directory are the receipts.
2. **Regression-by-example.** If we ever want to test whether a refactor preserves the gate's catching power, we can re-run the originating task and compare the new brief against the saved one.

## What lives here

Each file is named `YYYY-MM-DD-<slug>-<outcome>-brief.md` where `<outcome>` is `verified | contradicted | not-applicable | couldnt-verify`.

The most useful ones are `contradicted` outcomes — those are the gate doing the work no other system in this space does.

## Index

| Date       | Task                                                | Outcome      | What it caught                                                                 |
|------------|------------------------------------------------------|--------------|--------------------------------------------------------------------------------|
| 2026-05-24 | Set up Stripe webhooks for the new tenant_policy update event | CONTRADICTED | Stripe webhooks don't support custom event types like `tenant_policy.updated`. The spec was conflating "domain event" with "Stripe webhook." |
| 2026-05-24 | Add a /llm-orchestrator:cost command tallying token spend from Claude Code JSONL transcripts | VERIFIED (with caveats) | Four implementation gotchas a naive build would have missed: no OS env var for session ID; `cache_creation_input_tokens` is a sum of two different rate buckets; $10/1k web-search surcharge needs separate accounting; Opus 4.7 tokenizer can inflate counts up to 35%. |
