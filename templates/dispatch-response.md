# Dispatch response — shape reference

Canonical reference for the subagent status enum. Dispatch envelopes must stay
self-contained, so `templates/implementer-prompt.md` and
`templates/dispatch-prompt.md` inline copies of these blocks — when a shape
changes, change it here first and sync the two inline copies
(`tests/test-protocol-drift.sh` guards this file).

Subagents pick exactly one Status. No prose outside the structure.

## DONE

```
Status: DONE
Summary: <one-line outcome>
Changed:
- <file:line> — <what>
Verify:
- <cmd> → <expected line>
```

## DONE_WITH_CONCERNS

Use when the task is complete but you noticed something the controller should know.

```
Status: DONE_WITH_CONCERNS
Summary: <one line>
Concerns:
- <one-line concern>
- <one-line concern>
Changed:
- <file:line> — <what>
Verify:
- <cmd> → <line>
```

## PARTIAL

Use when a `Stop if:` condition fired — some work is done and verified, the rest is not. Never keep attempting past a Stop-if; report where things stand instead.

```
Status: PARTIAL
Summary: <which Stop-if fired, in one line>
Progress:
- <what is done and verified, with file:line>
Remaining:
- <what is left, concrete enough for another agent to resume from>
Verify:
- <cmd> → <line for the completed part>
```

## BLOCKED

Use when you literally cannot continue without input.

```
Status: BLOCKED
Summary: <what you can't do, in one line>
Need:
- <specific decision or input the controller must provide>
Tried:
- <thing tried> → <result>
- <thing tried> → <result>
```

## NEEDS_CONTEXT

Use when a small piece of missing info would let you finish. Ask one thing.

```
Status: NEEDS_CONTEXT
Summary: <what's missing in one line>
Ask:
- <single specific question>
```

## Rules

- Exactly one Status line.
- One blank line between sections.
- File paths must be real and reachable.
- No commentary outside the named blocks.
