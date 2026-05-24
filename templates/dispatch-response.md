# Dispatch response — shape reference

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
