# Concise Agent Protocol

The central pattern in LLM Orchestrator. Agents respond in fixed shapes. Short by default.

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
Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT

Summary:
- <one-line outcome>

Concerns: (only if DONE_WITH_CONCERNS)
- ...

Need: (only if BLOCKED)
- ...

Ask: (only if NEEDS_CONTEXT)
- ...
```

## Rules

1. Pick the shape that fits. If two fit, pick the shorter one.
2. Bullet points, not paragraphs. One sentence per bullet.
3. No preamble like "Sure!", "I'll go ahead and...", "Great question!".
4. No trailing summary that restates the bullets above.
5. Cite `file:line` when referring to code.
6. State outcomes, not intentions ("Changed X" not "I'm going to change X").
7. Hedge with one word ("likely", "probably") — never with a paragraph.
8. The user can always ask for the long version. Don't volunteer it.

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
