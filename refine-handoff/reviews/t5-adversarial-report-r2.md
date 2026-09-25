Seven fixes hold; **#3 remains partly unfixed**. Reviewed committed `HEAD` (`1df09b3`); excluded concurrent uncommitted edits. No files edited or models called.

Round 1 status:

1. **Fixed in code:** required Bash sandbox, restricted mode and reduced environment. Live containment was not tested; the flags match [Claude’s documented controls](https://code.claude.com/docs/en/sandboxing).
2. **Fixed:** missing findings now produce `INCOMPLETE`.
3. **Partly fixed:** a failing receipt prevents quotation-based drops; an unrun experiment still permits unsupported drops.
4. **Fixed:** clones use `--no-hardlinks`.
5. **Fixed:** the timeout probe confirmed the descendant was killed.
6. **Fixed by refusal:** submodule repositories return `INCOMPLETE` before reviewers start.
7. **Fixed:** background acknowledgements are rejected as evidence.
8. **Fixed:** missing verdict plus rank reduction produces `INCOMPLETE`, retaining serious rank.

Remaining finding:

1. **CATASTROPHIC — unsupported quotation drops a serious defect → `READY` — EXECUTED ([drop_allowed](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:942)).**  
   SCENE: given a specification requiring addition and code returning `a - b`; when the experiment sandbox is unavailable, the refuter quotes `return a - b` and falsely says “the spec asks for the difference”; expect the defect to remain blocking. The actual validation/refutation/decision pipeline returned `READY`, `status=dropped`. Matching the finding’s file and line still does not establish contradiction.

Verification: BLOCKED — in-memory and process probes ran; end-to-end tests and live sandbox enforcement remain unverified under read-only constraints.