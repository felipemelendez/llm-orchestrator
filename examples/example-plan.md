# Token-aware rate limit — Plan

Date: 2026-05-23
Spec: docs/llm-orchestrator/specs/2026-05-23-token-rate-limit-spec.md

## Goal
- Limit API users to 100k tokens per 1-minute window, backed by Redis.

## Files
- create: src/lib/rate-counter.ts
- create: src/lib/rate-counter.test.ts
- modify: src/middleware/rate-limit.ts:12–55
- modify: src/middleware/rate-limit.test.ts

## Tasks

### 1. Redis counter helper
Independent: yes
Owner: implementer

Steps:
- [ ] write failing test in `src/lib/rate-counter.test.ts` covering: increment, expire, read.
- [ ] run: `pnpm test rate-counter` — expect: 3 failing
- [ ] implement `src/lib/rate-counter.ts` with `RateCounter.add(userId, n)` and `RateCounter.get(userId)`.
- [ ] run: `pnpm test rate-counter` — expect: 3 passed
- [ ] commit: `feat(lib): redis-backed rate counter`

### 2. Wire into middleware
Independent: no — depends on 1
Owner: implementer

Steps:
- [ ] modify `src/middleware/rate-limit.ts:12` to consume `RateCounter`.
- [ ] write failing test in `src/middleware/rate-limit.test.ts` for "blocks after 100k tokens".
- [ ] run: `pnpm test rate-limit` — expect: 1 failing
- [ ] implement gating in `rate-limit.ts`.
- [ ] run: `pnpm test rate-limit` — expect: 5 passed
- [ ] commit: `feat(middleware): token-aware rate limit`

### 3. 429 with Retry-After
Independent: yes
Owner: implementer

Steps:
- [ ] write failing test for "429 response includes Retry-After: 60".
- [ ] run: `pnpm test rate-limit` — expect: 1 failing
- [ ] implement in `rate-limit.ts:48–55`.
- [ ] run: `pnpm test rate-limit` — expect: 1 passed
- [ ] commit: `feat(middleware): 429 with Retry-After header`

## Risks
- Redis unavailability fails open by default — accept; add metric in follow-up.
- Token cost estimation accuracy depends on the upstream model's pricing — accept; we use server-side token counts.

## Verify done
- `pnpm test` — expect: all green, 146 passed
- `pnpm typecheck` — expect: 0 errors
