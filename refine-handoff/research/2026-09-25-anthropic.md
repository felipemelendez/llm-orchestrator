# What Anthropic shipped and published, March to September 2026, and what it means for the plugin

Researched 2026-09-25 against Claude Code v2.1.282 (installed locally). Claude
Code doc pages carry no publication date, so a page is cited as "read
2026-09-25" together with the version the page or the changelog names. Weekly
digest dates come from `code.claude.com/docs/en/whats-new/`. "Local" means
checked on this machine with v2.1.282. Anything not confirmed is marked
**unverified**.

## Findings

### Subagents

- Supported agent frontmatter: `tools`, `disallowedTools`, `model`,
  `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`,
  `background`, `omitClaudeMd` (v2.1.271), `effort`, `isolation`, `color`,
  `initialPrompt`, `experimental.cacheTtl` (v2.1.248). Plugin agents ignore
  `hooks`, `mcpServers` and `permissionMode`.
  <https://code.claude.com/docs/en/sub-agents> (read 2026-09-25)
- Model order for a subagent: the per-call `model` first, then frontmatter,
  then `CLAUDE_CODE_SUBAGENT_MODEL`, then the main session's model (order
  changed in v2.1.251). `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` overrides every
  agent's frontmatter (v2.1.257). If the main session is on an Opus model,
  `model: opus` runs the session's exact Opus model, including `[1m]`.
  <https://code.claude.com/docs/en/sub-agents#choose-a-model> (read 2026-09-25)
- On the Anthropic API, `opus` now means Opus 5.5 (v2.1.280) and `fable` means
  Fable 5.1 (v2.1.257). <https://code.claude.com/docs/en/model-config> (read
  2026-09-25); <https://code.claude.com/docs/en/whats-new/2026-w36> (Aug 31 to
  Sep 4, 2026)
- The Agent tool's inputs are `description`, `prompt`, `subagent_type`,
  `model` (alias only), `run_in_background`, `name` and `isolation`
  (`worktree` or `remote`). It has no `effort` input.
  <https://code.claude.com/docs/en/agent-sdk/typescript> (read 2026-09-25)
- The built-in Explore agent now runs on the main session's model, capped at
  Opus, instead of Haiku (v2.1.198). It skips CLAUDE.md.
  <https://code.claude.com/docs/en/whats-new/2026-w27> (Jun 29 to Jul 3, 2026)
- Fork mode is on by default in interactive sessions (v2.1.232), so every
  subagent Claude starts runs in the background. Background subagents keep only
  a fixed list of built-in tools (`Read`, `Grep`, `Glob`, `LSP`, `Bash`, `Edit`,
  `Write`, `WebFetch`, `WebSearch`, `TodoWrite`, `Skill`, `ToolSearch`,
  worktree tools, `Monitor`, `TaskStop`, `SendMessage`, `Artifact`,
  `SubagentHandback`). <https://code.claude.com/docs/en/whats-new/2026-w33>
  (Aug 10 to 14, 2026); <https://code.claude.com/docs/en/sub-agents#available-tools>
- Subagents can start their own subagents, three levels deep by default
  (v2.1.219; `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`). Twenty can run at once by
  default. <https://code.claude.com/docs/en/sub-agents> (read 2026-09-25)
- A subagent that stops at `maxTurns` now returns its output marked as partial
  (v2.1.246). <https://code.claude.com/docs/en/whats-new/2026-w35> (Aug 24 to
  28, 2026)
- **The task tools are gone on current models.** `TaskCreate`, `TaskGet`,
  `TaskUpdate`, `TaskList` and `TodoWrite` are provided by default only on
  Claude 3.x, Opus 4 to 4.7, Sonnet 4 to 4.6 and Haiku 4.5. They are absent on
  Opus 4.8 and later, Sonnet 5 and Fable 5 and later, unless the user sets
  `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`. Subagents get them only if the session has
  them. <https://code.claude.com/docs/en/whats-new/2026-w33> (Aug 10 to 14,
  2026); <https://code.claude.com/docs/en/tools-reference#task-tool-availability>
  (v2.1.268)
- **`SubagentHandback` changes what SubagentStop sees.** In auto mode, a local,
  non-fork subagent delivers its report through the `SubagentHandback` tool
  (v2.1.271). SubagentStop's `last_assistant_message` then holds only the
  subagent's closing text, not the report; the report is the tool call's
  `tool_input.message`, visible to a PreToolUse or PostToolUse hook matched on
  `SubagentHandback`. Auto mode became the default permission mode for new
  sessions on Pro, Max and Team on 2026-08-14.
  <https://code.claude.com/docs/en/hooks#subagentstop>;
  <https://code.claude.com/docs/en/tools-reference>;
  <https://code.claude.com/docs/en/whats-new/2026-w32> (Aug 3 to 7, 2026).
  Local: this research agent was given `SubagentHandback`.
- `isolation: worktree` branches from the remote default branch by default.
  The setting `worktree.baseRef: "head"` makes it branch from local `HEAD`
  (committed work only). A plugin cannot set this: a plugin's `settings.json`
  honors only `agent` and `subagentStatusLine`. A `WorktreeCreate` hook can
  replace worktree creation entirely.
  <https://code.claude.com/docs/en/worktrees#choose-the-base-branch>;
  <https://code.claude.com/docs/en/whats-new/2026-w19> (May 4 to 8, 2026);
  <https://code.claude.com/docs/en/plugins/components> (read 2026-09-25)
- Worktree isolation also blocks Bash commands and git redirects that reach the
  main checkout (v2.1.220 to v2.1.224).
  <https://code.claude.com/docs/en/whats-new/2026-w32> (Aug 3 to 7, 2026)
- The `skills:` field injects the full text of each listed skill at start.
  Skills with `disable-model-invocation: true` cannot be preloaded. The
  `memory:` field (`user`, `project`, `local`) gives an agent its own
  `MEMORY.md` and does nothing when auto memory is off.
  <https://code.claude.com/docs/en/sub-agents#preload-skills-into-subagents>
- Messages from other agents carry no user authority, and subagent reports are
  scanned for text that imitates harness output (v2.1.210).
  <https://code.claude.com/docs/en/sub-agents#subagent-output-scanning>

### Skills and commands

- Commands are merged into skills: `commands/x.md` and `skills/x/SKILL.md` both
  create `/x`, and old command files keep working.
  <https://code.claude.com/docs/en/skills> (read 2026-09-25)
- Skill frontmatter now includes `disable-model-invocation`, `user-invocable`,
  `context: fork`, `agent`, `background` (default true, v2.1.218), `model`,
  `effort`, `disallowed-tools`, `paths` and `hooks`. With
  `disable-model-invocation: true` the description is not in context at all.
  A backgrounded `context: fork` skill gets the narrow background tool set.
  <https://code.claude.com/docs/en/skills#frontmatter-reference>
- Skill text stays in context after it loads; after compaction Claude Code
  keeps the first 5,000 tokens of each recent skill, 25,000 in total.
  <https://code.claude.com/docs/en/skills#skill-content-lifecycle>
- `/code-review` is a bundled skill that runs as a background subagent
  (v2.1.218). v2.1.215 stopped Claude from running `/verify` and `/code-review`
  on its own. v2.1.246 says Claude "can also start it on its own" on Bedrock,
  Vertex AI and Foundry, which implies it can on the Anthropic API too. Local:
  in a v2.1.282 session, `code-review` is in the list of skills the agent may
  invoke. `/verify` and `/deep-research` stay user-only. The docs do not state
  `/code-review`'s current status directly, so this is **partly verified**.
  <https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md>;
  <https://code.claude.com/docs/en/commands> (read 2026-09-25)
- `/code-review` at `low`/`medium` reports only high-confidence findings;
  `high` to `max` report more, including less certain ones. It reads CLAUDE.md
  but not `REVIEW.md`. <https://code.claude.com/docs/en/code-review#review-a-diff-locally>
- `claude plugin details` reports a plugin's context cost. Local:
  llm-orchestrator 0.11.0 adds about 3,067 tokens to every session (34 skills
  including the 15 commands, 7 agents), on top of what the SessionStart hook
  injects. `/skill-doctor` (v2.1.252) lists unused skills.
  <https://code.claude.com/docs/en/plugins/measure>;
  <https://code.claude.com/docs/en/whats-new/2026-w36>
- Anthropic's own review plugins still ship `commands/` and use cheaper agents:
  `code-review` uses Haiku and Sonnet agents with a 0 to 100 confidence score
  and a cut at 80; `feature-dev` agents use `model: sonnet`. Last changed
  2026-02-20 (`code-review`, `feature-dev`) and 2026-04-28 (`pr-review-toolkit`).
  <https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review>

### Hooks

- Stop and SubagentStop can return `hookSpecificOutput.additionalContext`,
  which keeps the turn going and is labelled as hook feedback rather than an
  error (v2.1.158). Claude Code ends the turn after 8 consecutive
  continuations. <https://code.claude.com/docs/en/hooks#stop-decision-control>;
  <https://code.claude.com/docs/en/whats-new/2026-w23> (Jun 1 to 5, 2026)
- `systemMessage` is a universal output field: "Warning message shown to the
  user". The Stop section names no exception.
  <https://code.claude.com/docs/en/hooks#json-output>
- Stop input now includes `last_assistant_message`, `background_tasks` (with
  each running shell command) and `session_crons`.
  <https://code.claude.com/docs/en/hooks#stop-input>
- Hooks receive the effort level as `effort.level` and `$CLAUDE_EFFORT`
  (v2.1.128 to v2.1.136). New events include `PostToolBatch`, `MessageDisplay`,
  `PreModelSwitch`/`PostModelSwitch`, `WorktreeCreate`/`WorktreeRemove` and
  `InstructionsLoaded`. Hook text fields are capped at 10,000 characters.
  <https://code.claude.com/docs/en/hooks>
- Hook matchers with hyphenated names now match exactly, not as substrings
  (v2.1.195). <https://code.claude.com/docs/en/whats-new/2026-w27>

### Workflow tool

- `agent(prompt, opts)` accepts `label`, `phase`, `schema`, `model`, `effort`,
  `isolation: 'worktree'` and `agentType`. There is no `cwd` option. The
  reference says to omit `model` unless sure a different tier fits. Scripts can
  also call `workflow()` (one level of nesting) and read `budget`. Source: the
  bundled `/workflow-authoring` skill in v2.1.282 (local). The public docs do
  not list `agent()` options.
  <https://code.claude.com/docs/en/workflows> (read 2026-09-25)
- Workflows became a research preview on 2026-05-28. Saved workflows live in
  `.claude/workflows/`; a plugin's `workflows/` directory is namespaced
  (`/plugin:name`); `args` passes input; runs resume in the same session;
  `Date.now()` and `Math.random()` throw; up to 16 agents at once and 1,000 per
  run; no input from the person mid-run.
  <https://code.claude.com/docs/en/workflows>;
  <https://claude.com/blog/introducing-dynamic-workflows-in-claude-code>
  (2026-05-28)
- `ultracode` is a setting, not an effort level: it sends `xhigh` and has
  Claude write a workflow for each substantive task (v2.1.203). The default size
  guideline is `medium` (fewer than 10 agents). Agents with the same model,
  effort, agent type, tools, schema and directory share a prompt cache.
  <https://code.claude.com/docs/en/workflows>

### Agent teams

- Still experimental and off unless `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.
  The docs point to subagents and cross-session messaging (v2.1.224) first.
  <https://code.claude.com/docs/en/agent-teams> (read 2026-09-25)

### `claude plugin eval`

- Released in v2.1.269 (week of 2026-09-07). Each case runs 3 times by
  default, with and without the plugin; graders are `regex`, `tool_used`,
  `tool_order`, `file_exists`, `llm` (2 of 3 judge votes) and `baseline`. The
  judge defaults to Haiku; the docs suggest `--judge-model sonnet` when a
  correct answer is marked wrong for formatting.
  <https://code.claude.com/docs/en/plugin-evals>;
  <https://code.claude.com/docs/en/whats-new/2026-w37>
- Runs are non-interactive (`-p`) sessions with no user settings, CLAUDE.md,
  memory or other plugins; `Bash` only when granted, under the OS sandbox.
  `--max-cost-usd` caps list-price spend. Local: `claude plugin eval --help`
  (v2.1.282) has no dry-run option.
  <https://code.claude.com/docs/en/plugin-evals#grant-tools>

### Output styles and memory

- Concise is a built-in output style (v2.1.237): result first, no preamble or
  recap, same engineering work.
  <https://code.claude.com/docs/en/whats-new/2026-w34> (Aug 17 to 21, 2026)
- A custom output style drops Claude Code's built-in software engineering
  instructions (scoping changes, verifying work) unless it sets
  `keep-coding-instructions: true`. Output styles do not reach non-fork
  subagents. <https://code.claude.com/docs/en/output-styles> (read 2026-09-25)
- Auto memory is on by default and saves `user`, `feedback`, `project` and
  `reference` notes; `MEMORY.md` loads up to 200 lines or 25KB. Claude Code
  reads `AGENTS.md` directly when no CLAUDE.md exists (v2.1.277).
  <https://code.claude.com/docs/en/memory>

### Models and effort

- Opus 5.5 defaults to `medium` effort; every other effort-capable model
  defaults to `high`. Haiku 4.5 supports no effort level.
  <https://code.claude.com/docs/en/model-config#adjust-effort-level>
- Opus 5.5 at `medium` matches or beats Opus 5 at `high` on coding, in fewer
  steps; early testers report stronger code review with fewer false alarms.
  Reserve `xhigh`/`max` for measured gains. Prompts that ask the model to write
  out its reasoning can be refused (`reasoning_extraction`).
  <https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5-5>
  (read 2026-09-25)
- Opus 5.5 may end a turn with a progress report on long unattended tasks. The
  guide says to treat a text-only end as a report, keep a checklist, and stop
  after 2 or 3 automatic continuations. Same source.
- Opus 5.5 costs about 40% less than Opus 5 for typical token-billed work;
  cached reads are 60% cheaper. <https://claude.com/blog/claude-opus-5-5-built-for-coding-sessions-that-use-more-context>
  (2026-09-24)
- Fable 5.1: describe the outcome, not the steps; "skip the verification
  reminders", since it checks its own work. At `low` it is often competitive
  with Opus and Sonnet on cost per task. It tends to add unrequested fixes and
  tests; the guide gives a prompt to keep changes and tests to what was asked.
  <https://code.claude.com/docs/en/model-config#work-with-fable>;
  <https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1>
- Fable 5.1, Fable 5 and Opus 5.5 all run safety classifiers. A
  cybersecurity-flagged request re-runs on Opus 4.8; a biology-flagged one on
  Opus 5. Finding vulnerabilities in source code is allowed on Opus 5.5.
  <https://code.claude.com/docs/en/model-config#automatic-model-fallback>
- The advisor tool requires an advisor at least as capable as the main model;
  for Opus 5.5 that means Fable or Opus 5 and later. Haiku cannot advise.
  <https://code.claude.com/docs/en/advisor> (read 2026-09-25)
- Model choice guidance: larger models for hard or ambiguous work, smaller
  models for routine, precisely described work; effort is a general preference,
  not a per-task choice. <https://claude.com/blog/claude-model-and-effort-level-in-claude-code>
  (2026-07-07). "Start with the most intelligent generally available model";
  Sonnet suits "high-volume sub-agents".
  <https://claude.com/blog/claude-models-explained-choosing-the-best-model-for-your-use-case>
  (2026-07-24). For a noisy job handed off repeatedly, give the agent
  `model: haiku` or `sonnet`.
  <https://claude.com/blog/maximizing-the-value-of-your-claude-code-sessions>
  (2026-08-14)

### Harness, review and verification guidance

- Separating the agent that works from the agent that judges helps, but "out
  of the box, Claude is a poor QA agent": it found real issues, then talked
  itself into approving. A reviewer is worth its cost when the task is beyond
  what the model does reliably alone. Simplify by removing one component at a
  time and measuring. <https://www.anthropic.com/engineering/harness-design-long-running-apps>
  (2026-03-24)
- Harness parts encode assumptions about what the model cannot do, and those
  go stale as models improve. <https://www.anthropic.com/engineering/managed-agents>
  (2026-04-08)
- Encode repeated manual checks as skills; list exact build and test commands
  in CLAUDE.md; the Claude Code team chains `/code-review`, `/simplify` and
  `/verify`. <https://claude.com/blog/building-verification-loops-in-claude-code-with-skills>
  (2026-07-22)
- The managed Code Review runs several finders, then a step that tries to
  disprove each finding; fewer than 1% of findings were marked incorrect.
  <https://claude.com/blog/code-review> (2026-03-09)

## What this means for the plugin

- **T1 (test commands).** The verification-loops post says to list exact test
  commands in CLAUDE.md, which supports reading `runner.test_cmd`. The Stop
  input's `background_tasks` shows a test still running, which may help the
  "backgrounded command does not count" rule.
- **T2 (notice).** Confirmed: `systemMessage` is shown to the person on Stop.
  Note that Stop `additionalContext` continues the turn (up to 8 times), so the
  note to the model makes the model act again.
- **T3 (quiet always-on layer).** Add: the plugin's always-on listing is about
  3,067 tokens before the SessionStart text; Fable 5.1 guidance says to drop
  verification reminders; the built-in Concise style now covers "no preamble".
  Also fix `output-styles/orchestrator.md`: it lacks
  `keep-coding-instructions: true`, so selecting it removes Claude Code's own
  engineering instructions. Consider replacing it with the built-in Concise
  style.
- **T4 and T5 (one review design).** `agent()` takes `model`, `effort`,
  `isolation` and `agentType` but no `cwd`, which confirms spec item 6. The
  script can ship in `workflows/` as `/llm-orchestrator:<name>`. The
  harness-design post supports briefing the refuter to be skeptical and
  calibrating it on logged misses. Consider `/code-review` as one of the two
  reviewers if T8 confirms Claude can start it.
- **T6 (legacy).** Consistent with "remove one component at a time and
  measure".
- **T7 (models).** Update more than the Fable name: `opus` is now Opus 5.5,
  whose default effort is `medium`, so agents that inherit effort run at
  `medium` unless the person sets another level. The security reviewer's reason
  for Opus ("Fable's classifiers fire on security work") no longer holds: Opus
  5.5 runs the same classifiers and falls back to Opus 4.8. For the explorer,
  Anthropic's guidance favors Sonnet for high-volume subagents; Sonnet 5
  supports effort and can act as an advisor, Haiku 4.5 does neither. Opus 5.5
  is also about 40% cheaper than Opus 5, which narrows the cost argument.
- **T8 (native features).** Answers so far: `/code-review` looks
  model-invocable again (partly verified; try it). Native worktrees branch from
  the remote default branch unless `worktree.baseRef: "head"`, which the plugin
  cannot set and which carries no uncommitted changes, so the plugin's own
  worktree and baseline scripts are still needed. `skills:` cannot preload
  user-only skills; `memory:` needs auto memory on; `context: fork` skills run
  in the background with a narrow tool set. `omitClaudeMd` is new.
- **T9 (commands to skills).** Supported by the docs. Setting
  `disable-model-invocation: true` also removes the description from context,
  which lowers the 3,067-token figure. Anthropic's own plugins still use
  `commands/`, so this stays low priority.
- **T10 (evals).** There is no dry-run flag, so "a dry run with no API calls"
  needs another form (for example `claude plugin validate` plus a check of the
  case files). Eval runs load no CLAUDE.md and run in `-p` mode (fork mode off),
  so they do not reproduce an interactive Pilot session. Pin `--model`, use
  `--judge-model sonnet`, set `--max-cost-usd`.
- **T11.** No change.
- **New T12: stop relying on the task tools.** `executing-plans`,
  `dispatching-subagents`, `dispatching-parallel-agents`, `using-orchestrator`
  and `commands/dispatch.md` use `TaskCreate`/`TaskUpdate`, which current models
  do not have. Use the plan file's checkboxes as the state, or document
  `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`.
- **New T13: read subagent reports sent through `SubagentHandback`.**
  `scripts/hooks/subagent-stop.sh`, `orch-researcher-validator.sh` and
  `orch-retry-cap.sh` read `last_assistant_message`. In auto mode that is not
  the report, so the `Status:` check may judge the wrong text. Reproduce first
  in auto mode; if confirmed, read `tool_input.message` from a hook on
  `SubagentHandback`. This changes existing hooks, so it needs Felipe's
  approval under the "no new hooks" rule.
- **New T14 (or part of T3): fix or retire the plugin output style** (see
  T3).

Possible conflicts with plugin choices, weaker than the above:

- Fable 5.1 guidance says to commit tests only where the task asks for them;
  the plugin enforces TDD. Worth checking whether the TDD skill produces extra
  test files on Fable 5.1 (not measured).
- Anthropic's `code-review` plugin uses Haiku and Sonnet reviewers, against the
  plugin's "reviewer at least as capable as the implementer" rule. That plugin
  was last changed in February 2026, and the advisor tool's current rule agrees
  with the plugin, so this is a weak signal.

## Open questions

- Can Claude start `/code-review` on its own on the Anthropic API in v2.1.282?
  The changelog and this session suggest yes; the docs do not say. Try it in a
  scratch repo (T8).
- Does `SubagentHandback` actually break the plugin's `Status:` check in auto
  mode? Not reproduced (T13).
- Does `worktree.baseRef: "head"` make the plugin's worktree scripts
  unnecessary for committed work? It does not carry uncommitted changes; the
  green-baseline capture still has no native equivalent (unverified in a live
  run).
- The `agent()` options come from the bundled skill text, not public docs.
  Confirm `effort` and `agentType` behave as described in a small test script
  before T5 depends on them.
- Engineering or research posts on anthropic.com after 2026-05-25 were not
  found; the engineering index lists none later. Some may exist and be missed
  (unverified).
