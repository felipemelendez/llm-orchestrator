# Dispatch prompt

Role: <implementer | explorer | spec-reviewer | code-reviewer | debugger>

## Scope
- <files or subsystem — single domain>

## Goal
- <one sentence>

## Context

Paste the relevant content directly. Do not reference paths.

Spec section:
```
<paste>
```

Plan task:
```
<paste>
```

Existing code (only what's needed):
```
<paste>
```

## Constraints
- Do not edit files outside scope.
- Do not invent new dependencies.
- Follow the project's Concise Agent Protocol.

## Verify
- Command: `<cmd>`
- Expected: `<line>`

## Return

Reply with one of:

```
Status: DONE
Summary: <one line>
Changed:
- <file:line> — <what>
Verify:
- <cmd> → <line>
```

```
Status: DONE_WITH_CONCERNS
Summary: <one line>
Concerns:
- <one line per concern>
Changed:
- ...
Verify:
- ...
```

```
Status: BLOCKED
Summary: <one line>
Need:
- <decision or input>
Tried:
- <what + result>
```

```
Status: NEEDS_CONTEXT
Summary: <one line>
Ask:
- <single specific question>
```
