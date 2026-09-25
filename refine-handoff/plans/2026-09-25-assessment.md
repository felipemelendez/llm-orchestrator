# Assessment of LLM Orchestrator v0.11.0 (2026-09-25)

## Verdict

The cadence is a good idea and well built: it sizes the review work to the risk
of the change. The plugin as a whole carries more than the cadence needs, and
some of its always-on rules slow down simple questions. The work below trims
the plugin so it stays light for small asks and reliable for long, complex
projects.

## How this was checked

- Read the cadence skill, the orchestration skills, the agents, every hook and
  `workflows/review-diff.js`.
- Ran `bash tests/run-all.sh`: all 46 suites passed.
- Ran the hooks by hand against sample prompts and against Pilot's real test
  commands.
- Compared the plugin with the Claude Code features and models available on
  2026-09-25 (Fable 5.1, Opus 5.5, Sonnet 5, Haiku 4.5).

## What is good and stays

- Simple, Standard and Full paths chosen by risk. Simple uses no extra agents.
- The lock over the rulebook, and the guard against git commands that discard
  uncommitted work.
- Each writing agent gets its own copy of the project, and branches merge back
  only when the tests pass on the combined result.
- Honest records in `docs/MEASUREMENTS.md`, including the experiments that
  failed.
- Hooks are cheap: about 800 tokens at session start, about 80 per turn, and
  about 0.35 seconds per shell command for the guards.
- Hooks that watched every command were removed in v0.10.0 because they cost
  more than they caught. None of the work below adds a hook.

## What we are addressing, and why

### 1. The completion check misses real test commands

`scripts/lib/orch-signals.sh` holds the pattern that decides whether a command
was a test run. It does not match `.ve/bin/pytest`,
`cd zapgram && .ve/bin/pytest`, `aws-vault exec … -- pytest` or
`pnpm vitest`, and the check ignores the `test_cmd` set in `cadence.json`. In a
project like Pilot, a real passing run is reported as having no check behind
it. Codex uses the same pattern, so it has the same gap.

### 2. The person never sees the completion warning

The README says the check "says so on screen". The code only sends a note to
the model after the reply has been shown, so a false PASS reaches the person
unchallenged. On Claude Code, one line shown to the person fixes this. On
Codex, Ruling 3 forbids output for the person, so Codex stays as it is.

### 3. The always-on layer is heavy for simple questions

Once installed, the plugin applies to every project, not only projects with
the cadence enabled. Every reply must open with one of six headers, and the
agent is told to "invoke relevant skills before responding", which makes it
start a brainstorm or debugging process for small asks. The headers also
compete with a project's own reply format, such as Pilot's CLAUDE.md.

### 4. The older, heavier pipeline is still the default

`skills/using-orchestrator/SKILL.md` says "don't implement features inline when
the orchestration path exists", which means brainstorm, spec, plan, then
dispatch. The README says "every non-trivial task runs research, planning,
fresh-context reviews". Both contradict the Simple, Standard and Full paths.

### 5. Two review systems that do not connect

`workflows/review-diff.js` runs a spec check, then a quality check, then a
verification pass. The cadence Full path uses its own pair of reviewers and an
optional refuter. `skills/cadence/CADENCE.md` says running the first does not
count for the second. The plugin should have one review design.

### 6. The Full path is not automated

On the Full path, the main agent has to follow written steps: start two
reviewers with separate briefs, keep their findings apart, compare them, and
decide whether the refuter runs. That is the step most likely to be skipped. A
Workflow script is a JavaScript file the agent runs once, on purpose; it does
not watch the agent. It can run the two reviewers, compare their findings and
start the refuter by fixed rules. The plugin already uses this mechanism for
`review-diff.js`. The written steps stay as the fallback for Codex and for
sessions without the Workflow tool.

### 7. The legacy procedure still ships

Most of the 572-line `CADENCE.md` and its 15 reference files describe
`workflow: legacy`, the older fixed sequence of five stage reports. If no
project still uses it, it is text an agent may read and follow by mistake.

### 8. Model documentation is out of date, and the explorer may cost too much

All seven agents are set to `model: opus` (Opus 5.5), by the policy recorded in
`tests/validate-skills.sh` on 2026-09-21. The README, `ARCHITECTURE.md` and
`docs/anthropic-ecosystem.md` still say "Fable 5", and the current Fable is 5.1.
The explorer is a read-only search agent; running it on Opus is expensive, and
Sonnet 5 or Haiku 4.5 would likely do (not measured).

### 9. Claims about native Claude Code features need re-checking

- The docs say the agent cannot run `/code-review` itself. In a Claude Code
  session on 2026-09-25, `code-review` was listed as a skill the agent can run.
- The plugin does not use several current features: `isolation: worktree` in
  agent files (the plugin says the native one branches from the wrong commit;
  not confirmed), preloading skills into agents, agent memory,
  `context: fork` for skills, and `claude plugin eval`.
- The 15 files in `commands/` would now usually be written as skills.

### 10. The benefit of the review steps is not measured

The committed benchmark runs 3 tries per case and shows only better reply
formatting. Without the plugin, the model fixed the bugs just as often. Nobody
has compared the Full path with the built-in `/code-review` on the same changes.

## Scope: Claude Code and Codex

Ruling 3 says "Claude Code and Codex, one policy", so changes to shared policy
apply to both.

- Both: items 1, 3 and 4 (where Codex reads the same instructions), 5 and 6
  (the written fallback), and 7.
- Claude Code only: item 2 (Codex is ruled out), the Workflow script in item 6,
  and items 8, 9 and 10.

The tickets are in `2026-09-25-tickets.md`.
