# 2026-08-04 — Transcript mining: the compression regression's mechanism

Numbers cited in `docs/MEASUREMENTS.md` ("invoked runs passed 76/77",
"post-cut invocation 0/205") come from mining the session transcripts of the
2026-08-03/04 eval runs, not from the archived benchmark JSONs. This note is
the method and the full table, recorded because the source transcripts live
outside the repo (`~/.claude-vega/projects/…llm-orch-evals-…/*.jsonl`, keyed
by scratch path, accumulating across runs) and are ephemeral.

Method: for every surviving `tdd-under-pressure` session transcript, bucket by
arm and mtime into its run; extract `Skill` tool invocations from assistant
`tool_use` blocks; detect a written covering test from Write/Edit inputs
(test-file path + an assertion on the reported input). The detector was
validated by reproducing every run's on-disk graded rate exactly (80/105≈76%,
68/100, 56/105, 56/100, 2/100 on the poisoned run).

| run (arm, date) | n | invoked ≥1 skill | wrote test |
|---|---|---|---|
| pre-cut ref, 08-03 | 105 | 25 | 80 |
| pre-cut ref, 08-04 | 100 | 23 | 68 |
| pre-cut ref, partial | 18 | 6 | 14 |
| post-cut, 08-03 | 105 | 0 | 59 |
| post-cut + TDD-body restored, 08-04 | 100 | 0 | 56 |

Key derived figures: post-cut invocation **0/205** (valid runs; 0/305 counting
the poisoned run's live minority); P(wrote test | invoked) = **76/77** pooled
across pre-cut runs vs ~65–70% for pre-cut non-invokers. This localized the
regression to the always-loaded invocation mandate — confirmed causally by the
2026-08-05 A/B (`2026-08-05-compression-mandate-kept-CONFIRMED.json`) — and
motivated the per-row `skills_invoked` telemetry now built into the runner,
which makes this mining unnecessary for future runs.

Falsification warning: these correlations also motivated the skill-nudge hook,
which measured WORSE (`2026-08-04-skill-nudge-AB-NEGATIVE-RESULT.json`).
Invocation predicts good runs; forcing it does not create them.
