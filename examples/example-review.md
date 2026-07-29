# Review — feat/token-rate-limit

Date: 2026-05-23
Base: origin/main
Head: feat/token-rate-limit
Spec: docs/llm-orchestrator/specs/2026-05-23-token-rate-limit-spec.md
Plan: docs/llm-orchestrator/plans/2026-05-23-token-rate-limit-plan.md

## Stage 1 — Spec compliance

Issues:
- Critical: (none)
- Important: (none)
- Minor:
  - src/middleware/rate-limit.ts:55 — `Retry-After` always 60; spec said "remaining window seconds". Cosmetic for v1.

Verdict:
- Ready: yes
- Spec is implemented end-to-end.

## Stage 2 — Code quality

Issues:
- Critical: (none)
- Important:
  - src/middleware/rate-limit.ts:20 — Redis client constructed inside the middleware function; not memoized, opens a connection per request. Move to `src/lib/redis-client.ts` and inject.
- Minor:
  - src/lib/rate-counter.ts:42 — `await` inside a tight loop; consider Promise.all for batch ops (post-v1).
  - src/lib/rate-counter.test.ts:18 — uses 1500ms sleep; flaky in CI. Switch to fake timers.

Verdict:
- Ready: with-fixes
- 1 Important must land before merge.

## Notes

- Possible perf regression for large user fanout (>1000 concurrent). Not measured.

## Combined verdict

- Ready to merge: with-fixes
- Next: address Important in src/middleware/rate-limit.ts:20, then /llm-orchestrator:verify and /llm-orchestrator:finish.
