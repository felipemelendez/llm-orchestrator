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
- Ready: yes | no | with-fixes
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

Verify: (required for DONE and DONE_WITH_CONCERNS)
- <the command you ran, and the output it printed>

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

## Injected blocks (single source)

Two hooks inject protocol text, on two different schedules, from the two marked blocks below. Edit them HERE — both hooks extract at runtime and only fall back to an embedded copy if this file is unreadable. `tests/test-protocol-drift.sh` fails if the surfaces drift.

The two schedules are not interchangeable, and the split follows Anthropic's current guidance:

- **After compaction — re-establish.** `SessionStart` (`source=compact`) injects the *recovery core* below. Compaction is the one moment the earlier context is genuinely gone: the `using-orchestrator` eager block was injected before the boundary and did not survive it, so this block has to stand alone. Anthropic names compaction as a place to re-hydrate context deliberately ("consider hydrating through tools … or during context compaction" — [Prompting best practices → Migrating away from prefilled responses](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)).
- **Every turn — nudge, don't restate.** `UserPromptSubmit` injects the *turn nudge* below. This text is paid for on every single exchange and accumulates for the life of the session, so it carries only the format contract the Stop-hook grader actually enforces, in its shortest self-contained form. It is deliberately a distillation, not a copy: Anthropic's Claude 5 guidance retired the practice of stating the same instruction in two places ("Earlier Claude models could sometimes need repeated instructions or be more likely to listen to instructions at the end of their context window than at the start… we could delete these repeat examples" — [The new rules of context engineering](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)), while still sanctioning one short end-of-context reminder for output shape and length ("In a long system prompt, pair the instruction with a short reminder near the end of the prompt" — [Prompting Claude Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)).

Anything an agent needs *once* — skill precedence, the working rules, the routing table — belongs in the `using-orchestrator` eager block or the skill body, not here. Repeating it per turn buys nothing on Claude 5 models and teaches the agent that this corpus repeats itself, which is what trains skimming.

### Recovery core — SessionStart, post-compaction only

Marker name is historical (`scripts/hooks/session-start.sh` reads it); the block is no longer per-turn.

<!-- orch-turn-reminder-start -->
LLM Orchestrator — the protocol still applies after this compaction boundary:
- Open with exactly one shape header on its own line: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:". "Changed:" blocks REQUIRE a "Verify:" line (real command + its output).
- When two skills both match, run them in this order: process (brainstorming, systematic-debugging, research-classifier) → implementation (test-driven-development, writing-plans, dispatching-*) → verification (requesting-code-review, verification-before-completion, finishing-a-branch).
- Cite file:line. Lead with the answer in one plain sentence; no preamble, no trailing summary.
<!-- orch-turn-reminder-end -->

### Turn nudge — UserPromptSubmit, every turn

Budget: 300 bytes. `tests/test-protocol-drift.sh` enforces the ceiling.

<!-- orch-turn-nudge-start -->
LLM Orchestrator — open this reply with exactly one shape header: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:". A "Changed:" block REQUIRES a "Verify:" line (real command + its output). Lead with the outcome.
<!-- orch-turn-nudge-end -->
