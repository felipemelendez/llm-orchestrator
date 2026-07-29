# Concise Agent Protocol

The central pattern in LLM Orchestrator. Agents respond in fixed shapes (fixed response formats) — six in total: Changed, Found, Blocked, Issues, Plan, Status. Short by default.

## Why

Most agent systems waste tokens on preamble, jargon, restated requirements, hedging, and trailing summaries. The Concise Agent Protocol replaces freeform prose with a small set of named shapes. Each shape has a single purpose and a strict structure.

Benefits:
- Cheaper runs (fewer output tokens).
- Faster to read.
- Easier to verify (the user knows where the verdict lives).
- Easier to lint (a hook can grade compliance).

## Shapes

### 1. Changed — default response for code edits

```
Changed:
- <file:line or path> — <one-line description>

Why:
- <one sentence per reason>

Verify:
- <a command, or a manual check, with expected outcome>
```

### 2. Found — research / read-only tasks

`Found:` is also the shape for explanation queries — "what does X do", "how does Y work" — not just locating code ("where is X").

```
Found:
- <key fact 1>
- <key fact 2>

Recommendation:
- <what to do, why this option>

Next:
- <one suggested action>
```

### 3. Blocked — when you cannot proceed

```
Blocked:
- <single sentence: what's stopping you>

Need:
- <what input or decision unblocks you>

Tried:
- <what you already attempted, with result>
```

### 4. Issues — code or design review

```
Issues:
- Critical: <file:line — what + why it matters>
- Important: <file:line — ...>
- Minor: <file:line — ...>

Verdict:
- Ready to merge: yes | no | with-fixes
- One-line reason
```

### 5. Plan — when proposing a multi-step approach

```
Plan:
- 1. <action> — <file or scope>
- 2. <action> — <file or scope>
- 3. <action> — <file or scope>

Risks:
- <one line per risk>

Verify after each step:
- <command or check>
```

### 6. Status — subagent → controller

```
Status: DONE | DONE_WITH_CONCERNS | PARTIAL | BLOCKED | NEEDS_CONTEXT

Summary:
- <one-line outcome>

Concerns: (only if DONE_WITH_CONCERNS)
- ...

Progress: (only if PARTIAL — what is done and verified)
- ...

Remaining: (only if PARTIAL — what is left, concrete enough to resume from)
- ...

Need: (only if BLOCKED)
- ...

Ask: (only if NEEDS_CONTEXT)
- ...
```

`PARTIAL` exists so a fired `Stop if:` condition has an honest exit: completed work is reported and kept, the remainder is enumerated, and nothing is silently redone or silently claimed.

## Rules

1. Pick the shape that fits. If two fit, pick the shorter one.
2. Bullet points, not paragraphs. One sentence per bullet.
3. No preamble like "Sure!", "I'll go ahead and...", "Great question!".
4. No trailing summary that restates the bullets above.
5. Cite `file:line` when referring to code.
6. State outcomes, not intentions ("Changed X" not "I'm going to change X").
7. Hedge with one word ("likely", "probably") — never with a paragraph.
8. The user can always ask for the long version. Don't volunteer it.

### Write for the engineer

The reader is a human engineer, not another agent. Clarity beats cleverness.

- Lead with the answer in one plain sentence; details after.
- Expand or avoid internal jargon and tool-names — "the research step," not "orch-researcher Trigger A"; "I'm stuck and need your input," not "Status: BLOCKED, branch 5."
- Spell out a term or acronym on first use.
- Short, common words over long ones; cut filler.
- The shapes and `file:line` refs stay; this governs the words inside them.
- Be brief: the fewest lines that fully answer. Stop when the question is answered. Expand only when asked.

## When to break the protocol

- The user asks an open question that doesn't fit a shape ("how do you feel about X?") — answer plainly.
- A design discussion where the value is in the prose — write the prose, but keep it tight.
- Tutorial / teaching contexts when explicitly requested.

In every case, ask yourself: would a senior engineer skim this and find it useful? If not, cut.

## Anti-patterns

- "Here's a comprehensive breakdown of..." — almost never wanted.
- Restating the user's request before answering.
- Padding bullets with adverbs ("very", "really", "extremely").
- Walls of explanation when the code change is one line.
- Trailing "Let me know if you need anything else!" lines.

## Linting

The Stop hook `scripts/hooks/orch-protocol-grader.sh` grades the controller's last reply against the six shapes after every turn (non-blocking by default; set `ORCH_STRICT_PROTOCOL=1` to block on failure). `scripts/protocol-lint.sh` is a standalone CLI for the same check. Subagent `Status:` blocks are validated by `scripts/hooks/subagent-stop.sh` (set `ORCH_STRICT_STATUS=1` to block).

## Per-turn reminder (single source)

The `UserPromptSubmit` hook injects the text between the markers below on every turn. Edit it HERE — the hook extracts this block at runtime and only falls back to an embedded copy if this file is unreadable. `tests/test-protocol-drift.sh` fails if the surfaces drift.

<!-- orch-turn-reminder-start -->
LLM Orchestrator — every turn:
- Invoke the matching skill first: bug/investigate → systematic-debugging; build/design → brainstorming; library+version → research-classifier; approved spec → writing-plans; diff ready → requesting-code-review; claiming done/fixed/passing → verification-before-completion; remember/forget → managing-memory. Read-heavy sweeps → dispatch the explorer subagent.
- Open with exactly one shape header on its own line: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:".
- "Changed:" blocks REQUIRE a "Verify:" line (real command + its output). "Where is / what files / find X" → "Found:". "Best approach / how should we" → "Plan:" with "Risks:".
- Cite file:line. No preamble, no trailing summary; lead with the answer in one plain sentence.
<!-- orch-turn-reminder-end -->
