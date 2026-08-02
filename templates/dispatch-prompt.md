# Dispatch prompt

Role: <implementer | explorer | spec-reviewer | code-reviewer | debugger>

## Scope
- <files or subsystem — single domain>

## Goal
- <one sentence>

## Context

Paste the content directly; don't reference paths. Give each paste its own tag.
A spec or a source file carries ``` fences and `##` headings of its own, so
markdown delimiters alone leave the agent unable to tell where your envelope
ends and the pasted file begins.

<spec_section>
<paste>
</spec_section>

<plan_task>
<paste>
</plan_task>

<existing_code>
<paste — only what's needed>
</existing_code>

## Constraints
- Do not edit files outside scope.
- Do not invent new dependencies.
- Follow the project's Concise Agent Protocol.

## Verify
- Command: `<cmd>`
- Expected: `<line>`

## Termination

- Done when: <the observable end state — e.g. "`<cmd>` exits green and every sub-step above is complete". This is the ONLY path to DONE.>
- Stop if: <the abort conditions — e.g. "2 consecutive failed fix attempts on the same test", "a file outside scope needs editing", "more than N tool calls". When one fires, stop trying and return PARTIAL (progress worth keeping) or BLOCKED (cannot proceed) — do not keep attempting.>

## Return

**The shape depends on the role.** Only the implementer returns a `Status:`
block; asking a read-only role for one gets you a contract it was never given.

| Role | Returns |
|---|---|
| implementer | the `Status:` enum below |
| explorer, debugger | `Found:` → `Recommendation:` → `Next:` |
| spec-reviewer, code-reviewer | `Issues:` → `Notes:` → `Verdict:` (`Ready: yes \| no \| with-fixes`) |

`Done when:` / `Stop if:` still apply to every role — but `PARTIAL` is an
implementer outcome. A read-only role that hits a `Stop if:` says so in its own
shape (`Found:` with what it got to, or `Verdict:` with what it could not judge).

Implementers reply with one of:

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
Status: PARTIAL
Summary: <one line — which Stop-if fired>
Progress:
- <what is done and verified>
Remaining:
- <what is left, concrete enough to resume from>
Verify:
- <cmd> → <line for the completed part>
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
