# Example walkthrough — adding token-aware rate limiting

A small end-to-end run through LLM Orchestrator. Imaginary feature, real shape.

## 1. Brainstorm

User:
> Our API limiter counts requests but ignores token cost. We need to rate-limit by tokens.

Agent invokes `brainstorming`. Two clarifying questions, one at a time:

```
Found:
- Existing limiter: src/middleware/rate-limit.ts (counts requests/min)
Question:
- Limit per: (A) API key, (B) user, (C) IP — pick one
```

User picks B. Next question:

```
Question:
- Reset window: (A) 1 min, (B) 1 hour, (C) sliding — pick one
```

User picks A. Agent proposes options:

```
Found:
- per-user token limit, 1-minute window
Options:
- A: In-memory counter — fast, lost on restart
- B: Redis-backed counter — slower, durable
Recommendation:
- B — restarts shouldn't reset quotas
Next:
- Confirm B and I'll write the spec.
```

User confirms. Agent writes `docs/llm-orchestrator/specs/2026-05-23-token-rate-limit-spec.md`.

## 2. Plan

User: `/llm-orchestrator:plan`

Agent invokes `writing-plans`, reads the spec, writes `docs/llm-orchestrator/plans/2026-05-23-token-rate-limit-plan.md`. Three tasks:

1. Add Redis counter helper. Independent.
2. Wire helper into rate-limit middleware. Depends on 1.
3. Add 429 response with `Retry-After`. Independent.

## 3. Worktree

User: `/llm-orchestrator:worktree`

```
Changed:
- worktree at .worktrees/token-rate-limit on branch feat/token-rate-limit
- baseline: 142 passed
Verify:
- (cd .worktrees/token-rate-limit && pnpm test)
Next:
- /llm-orchestrator:dispatch task 1 and task 3 in parallel.
```

## 4. Dispatch

User: `/llm-orchestrator:dispatch 1,3`

Agent dispatches two implementers in parallel. Both return:

```
Status: DONE
Summary: implemented Redis counter helper
Changed:
- src/lib/rate-counter.ts:1–60 — new helper
- src/lib/rate-counter.test.ts — 4 tests
Verify:
- pnpm test rate-counter → 4 passed
```

```
Status: DONE
Summary: added 429 with Retry-After
Changed:
- src/middleware/rate-limit.ts:48–55 — 429 + header
- src/middleware/rate-limit.test.ts — 1 test
Verify:
- pnpm test rate-limit → 5 passed
```

Then task 2 (depends on 1):

```
Status: DONE_WITH_CONCERNS
Summary: wired counter into middleware
Concerns:
- Redis client construction lives in middleware; should move to lib/ before next refactor
Changed:
- src/middleware/rate-limit.ts:12–48 — uses rate-counter helper
Verify:
- pnpm test → 145 passed
```

## 5. Review

User: `/llm-orchestrator:review`

Stage 1 — spec compliance. Verdict: yes.
Stage 2 — code quality. One Important issue: missing test for the concern.

```
Issues:
- Critical: 0
- Important: 1 — src/middleware/rate-limit.ts:20 lacks a test for the new client construction
- Minor: 2
Verdict:
- with-fixes — address 1 Important before merging
Next:
- Add the missing test, then /llm-orchestrator:verify and /llm-orchestrator:finish.
```

## 6. Verify

User: `/llm-orchestrator:verify`

```
Verify:
- typecheck: 0 errors
- lint: 0 warnings
- test: 146 passed
Next:
- /llm-orchestrator:finish
```

## 7. Finish

User: `/llm-orchestrator:finish`

```
Found:
- Branch: feat/token-rate-limit
- Worktree: .worktrees/token-rate-limit (LLM Orchestrator-created)
- Tests: 146 passed
- Review: yes (after fix)
Options:
- 1. Merge into main
- 2. Push and open PR
- 3. Keep
- 4. Discard
Recommendation:
- 2 — public API change; PR review is cheap insurance
```

User picks 2. PR opened. Worktree preserved.
