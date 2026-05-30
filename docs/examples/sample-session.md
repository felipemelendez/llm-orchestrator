# Response-shape examples

Example response shapes you'll see when using the orchestrator: planning, a code change, memory, and blocked-recovery.

---

## A "best approach" question returns a `Plan:`, not prose

```
> What's the best approach to add a /healthz endpoint?

Plan:
- 1. Add a GET /healthz handler returning 200 + {status:"ok"}
- 2. Register it ahead of the auth middleware
- 3. Add a test asserting 200 and the JSON body

Risks:
- Mounting it after auth would 401 the health probe

Verify after each step:
- Step 3: run the test suite, expect the new test green
```

Hand the plan straight back as `/llm-orchestrator:plan` input — no re-prompting needed.

---

## A code change reports `Changed:` with a `Verify:` line

```
> Guard the user lookup against a missing session

Changed:
- src/users.ts:42 — return null when session is undefined
- src/users.test.ts — new test: guest with no session
Verify:
- <project test command> → the new test passes, suite stays green
```

A `Changed:` block without a `Verify:` line is treated as incomplete — the protocol requires the proof, not the promise.

---

## Memory persists across a restart

```
> /llm-orchestrator:remember Dana owns the billing service

Changed:
- ./CLAUDE.md — added under ## People
Verify:
- tail ./CLAUDE.md
```

Quit and reopen Claude Code — `./CLAUDE.md` is loaded natively at session start, so the fact survives. The classifier picks the section (`## People` here); you don't have to.

---

## A blocked task recovers without paging you

A two-task plan where task 2 needs a constant that task 1 exports. If task 2 is dispatched first:

```
[orch-implementer, task 2]
Status: BLOCKED
Need: src/constants.ts exporting ISO_DATE_REGEX — file does not exist
```

The controller routes through the "waiting on a sibling" recovery branch: it dispatches task 1 first, then re-dispatches task 2 with task 1's output in context.

```
[orch-implementer, task 1]          Status: DONE
[orch-implementer, task 2, retry]   Status: DONE
```

Two dispatches, one autonomous recovery, zero user interruptions.
