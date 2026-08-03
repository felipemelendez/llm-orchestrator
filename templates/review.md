# Review artifact template

The shape of the review saved to `docs/llm-orchestrator/reviews/YYYY-MM-DD-<slug>-review.md`
by `/llm-orchestrator:review` and `requesting-code-review`. Include the Stage 3 section only
when the conditional security pass ran; otherwise omit it entirely.

---

# Review — <branch or PR>

Date: YYYY-MM-DD
Base: <ref>
Head: <ref>
Spec: docs/llm-orchestrator/specs/<file>
Plan: docs/llm-orchestrator/plans/<file>

## Stage 1 — Spec compliance

Issues:
- Critical:
  - <file:line> — <what + why it matters + suggested fix>
- Important:
  - ...
- Minor:
  - ...

Verdict:
- Ready: yes | no | with-fixes
- <one-line reason>

## Stage 2 — Code quality

Issues:
- Critical:
  - ...
- Important:
  - ...
- Minor:
  - ...

Verdict:
- Ready: yes | no | with-fixes
- <one-line reason>

## Stage 3 — Security (only when the security pass ran)

Issues:
- Critical:
  - <file:line> — <what + why it matters + suggested fix>
- Important:
  - ...
- Minor:
  - ...

Verdict:
- Ready: yes | no | with-fixes
- <one-line reason — Critical blocks the merge; Important and below are advisory>

## Notes

- (Speculation goes here, never in Issues.)

## Combined verdict

- Ready: yes | no | with-fixes
- Next: <one-line>
