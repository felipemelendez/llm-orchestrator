# Manual testing game plan

The automated suite (`tests/smoke.sh`, `tests/validate-skills.sh`, `tests/test-portability.sh`) verifies mechanics. This document is for **end-to-end verification inside a live Claude Code session** — making sure the plugin loads, hooks fire, the agent replies in protocol shape, and the orchestration loop actually drives work.

Two paths:

- **Smoke (15 min)** — phases 0–3. "Does anything work at all?"
- **Full (60–90 min)** — all phases. "Is this safe to publish?"

Run smoke before every commit, full before publishing or before a big behavior change.

---

## Phase 0 — Pre-flight (terminal, no Claude Code yet) — 1 min

```bash
cd ~/LLM-Orchestrator
./tests/validate-skills.sh        # → "OK: 19 skills, 15 commands, 7 agents"
./tests/test-portability.sh       # → "7 portability checks passed."
./tests/test-lib-resolution.sh    # → "PASS: test-lib-resolution (5 checks)"
./tests/smoke.sh                  # → "81 checks passed, 1 skipped."
```

**Pass criterion:** all four exit 0. If any fails, fix before continuing — Claude Code testing won't tell you anything useful until the mechanics are sound.

---

## Phase 1 — Plugin install — 2 min

Pick one of these paths:

### Path A — Symlink + marketplace (recommended for dev)

```bash
./scripts/install.sh --link
# → "Linked /Users/.../LLM-Orchestrator -> /Users/.../.claude/llm-orchestrator"
```

Open a Claude Code session **in any project**, then:

```
/plugin marketplace add ~/.claude/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

### Path B — Per-project copy

```bash
./scripts/install.sh --copy ~/some-test-project
```

Follow `docs/install.md` "Wiring hooks for a --copy install" — either install the same path as a plugin (recommended) or hand-edit `.claude/settings.json`.

### Verify install

In a Claude Code session:

```
/plugin list
```

**Pass criteria:**
- `llm-orchestrator` appears in the list
- Version `0.7.0`
- Status: enabled

**Troubleshooting:**
- Plugin not listed → check the marketplace path is correct (`ls ~/.claude/llm-orchestrator/.claude-plugin/plugin.json` should resolve)
- Plugin listed but disabled → run `/plugin enable llm-orchestrator`

**Restart the Claude Code session** after installing. Hooks only register on session start.

---

## Phase 2 — Bootstrap verification — 2 min

In a fresh Claude Code session (post-install, post-restart):

### 2.1 Statusline

Look at the bottom of the Claude Code UI. You should see something like:

```
Claude Sonnet 4.6 · prof:standard · mem:0
```

(If memory is empty, `mem:` may be absent. If you're in a project with a recent plan, you'll see `plan:<filename>`.)

**Pass:** statusline shows the model name plus `prof:standard`.
**Fail:** default Claude Code statusline (no `prof:` prefix). `statusLine` is not a plugin-manifest field, so this is opt-in: point `statusLine.command` in your own `.claude/settings.json` at `scripts/statusline.sh`.

### 2.2 SessionStart hook fired

Ask the agent:

```
What response protocol are you using? List the six shapes.
```

**Pass:** the agent names `Changed`, `Found`, `Blocked`, `Issues`, `Plan`, and `Status` (the six shapes from the Concise Agent Protocol). It knows because the SessionStart hook injected the meta-skill into context.

**Fail:** agent says "I'm not aware of a specific protocol" or rambles — the SessionStart hook isn't firing or its output isn't reaching context. Run:

```bash
CLAUDE_PLUGIN_ROOT=~/.claude/llm-orchestrator bash ~/.claude/llm-orchestrator/scripts/hooks/session-start.sh | head
```

Should print valid JSON with the protocol body inside `additionalContext`.

### 2.3 Slash commands registered

Type `/` and look for the commands:

```
/llm-orchestrator:debug
/llm-orchestrator:dispatch
/llm-orchestrator:finish
/llm-orchestrator:forget
/llm-orchestrator:handoff
/llm-orchestrator:init
/llm-orchestrator:onboard
/llm-orchestrator:plan
/llm-orchestrator:remember
/llm-orchestrator:research
/llm-orchestrator:review
/llm-orchestrator:skills
/llm-orchestrator:verify
/llm-orchestrator:worktree
```

**Pass:** all 14 appear in the completion menu (`ls commands/*.md | wc -l` is the source of truth).
**Fail:** none appear → `commands/` directory not discovered. Check `/plugin list` shows the plugin enabled.

---

## Phase 3 — Response shape — 5 min

The agent should reply in one of the six named shapes, not free prose.

### 3.1 Trigger a `Found:` reply

```
What files in this repo handle authentication?
```

**Pass:** reply opens with `Found:` (or `Blocked:` if there's no auth code). Contains `file:line` references. No preamble like "Sure!" or "Let me look at that for you."

**Fail:** reply opens with multi-paragraph prose. The meta-skill isn't being followed → check that the SessionStart context contains the protocol (phase 2.2).

### 3.2 Trigger a `Changed:` reply

In a sandbox project, ask:

```
Add a one-line comment to the top of README.md saying "Hello".
```

**Pass:** reply opens with `Changed:`, lists `README.md:1 — added comment`, includes a `Verify:` line.

### 3.3 Trigger a `Plan:` reply

```
What's the best approach to migrate this project from npm to pnpm?
```

**Pass:** reply opens with `Plan:` containing numbered steps, then `Risks:`, then `Verify after each step:`.

If all three phase-3 tests pass, the protocol is live. This is the smoke path's stopping point.

---

## Phase 4 — Memory round-trip — 10 min

The plugin's memory layer writes to Claude Code's native CLAUDE.md (classified on write) and soft-deletes via `.trash/`. Test end-to-end.

### 4.1 Write a fact

```
/llm-orchestrator:remember pnpm not npm
```

**Pass:**
- Agent replies with a `Changed:` block citing `./CLAUDE.md` (or `./.claude/CLAUDE.md` if that's where the project keeps it)
- Run from terminal: `cat ./CLAUDE.md` — the fact appears under `## Conventions`
- The `## Conventions` section was created if it didn't exist

**Fail:**
- "command not found: with_lock" → `scripts/lib/orch-lock.sh` isn't sourced. Check the install (Path A: symlink should resolve `$CLAUDE_PLUGIN_ROOT/scripts/lib/`; Path B: check `~/your-project/.claude/scripts/lib/`).
- Fact lands in `~/.llm-orchestrator/memory/<hash>.md` instead of `./CLAUDE.md` → routing logic didn't fire. Verify the fact wasn't `research_aggressiveness:`-shaped (which correctly routes to plugin memory).

### 4.2 Restart and verify Claude Code loads the fact

Close Claude Code completely. Reopen in the same project.

Ask:

```
What's our package manager?
```

**Pass:** agent answers "pnpm, not npm" — Claude Code loaded `./CLAUDE.md` automatically at session start. This is native loading, not the plugin's hook.

### 4.3 Write a plugin-config fact (routes to plugin memory)

```
/llm-orchestrator:remember research_aggressiveness: high
```

**Pass:**
- Agent replies with `Changed:` citing `~/.llm-orchestrator/memory/<hash>.md` under `## Research config`
- Run: `cat ~/.llm-orchestrator/memory/<hash>.md` — section + entry present
- This fact does NOT land in `./CLAUDE.md` (it's internal state, not user-facing)

### 4.4 Forget with confirmation

```
/llm-orchestrator:forget pnpm
```

**Pass:**
- Agent shows the matching line(s) in a `Found:` block, grouped by source file (`./CLAUDE.md`, etc.)
- Asks for the literal word `forget` to confirm
- After confirmation, replies with `Changed:` citing the source file and the trash file
- Run: `ls ~/.llm-orchestrator/memory/.trash/` — backup file exists
- Run: `grep pnpm ./CLAUDE.md` — no matches

### 4.5 Forget guards (negative tests)

```
/llm-orchestrator:forget .*
```

**Pass:** agent refuses — pattern too generic / matches a section header. (`forget.md` step 3 catastrophic-delete guard.)

```
/llm-orchestrator:forget xy
```

**Pass:** agent refuses — pattern < 3 chars.

If all of 4.1–4.5 pass, the memory layer works end-to-end. Native CLAUDE.md is the persistence; the plugin adds classification on write and recoverable soft-delete on remove.

---

## Phase 5 — Orchestration loop — 20–30 min

The heart of the system. Use a sandbox project (or a tiny throwaway feature in a real project).

### 5.1 Setup

```bash
cd /tmp && mkdir orch-test-feature && cd orch-test-feature
git init -q && git commit --allow-empty -q -m initial
echo '{}' > package.json
```

Open a Claude Code session in this directory.

### 5.2 Brainstorm + plan

```
Add a function that returns the current ISO timestamp.
```

**Pass:** agent invokes `brainstorming` (it should ask one targeted question or propose 2 options with a recommendation). User confirms an option.

Then the agent should:
- Write `docs/llm-orchestrator/specs/2026-XX-XX-iso-timestamp-spec.md`
- Suggest `/llm-orchestrator:plan`

Run `/llm-orchestrator:plan`. **Pass:**
- Writes `docs/llm-orchestrator/plans/2026-XX-XX-iso-timestamp-plan.md`
- File contains tasks with `Independent:` and per-task `Files:` lines

### 5.3 Worktree

```
/llm-orchestrator:worktree
```

**Pass:**
- New directory `.worktrees/iso-timestamp/` (or similar)
- Marker file `.orch-worktree` inside the worktree
- `.gitignore` updated to include `.worktrees/`

### 5.4 Dispatch

```
/llm-orchestrator:dispatch
```

**Watch for:**
- Agent calls `TaskCreate` to create one task per plan task
- Agent dispatches `orch-implementer` (you'll see Task tool calls in the conversation)
- After implementer returns, agent dispatches `orch-spec-reviewer`
- Then `orch-code-reviewer`
- Tasks marked `completed` via `TaskUpdate`
- Plan file's `- [ ]` heading-level checkboxes ticked

**Pass criteria:**
- The implementer returns a `Status:` block with one of DONE / DONE_WITH_CONCERNS / PARTIAL / BLOCKED / NEEDS_CONTEXT (DONE and DONE_WITH_CONCERNS also require `Verify:`). The read-only agents return `Found:` or `Issues:` instead.
- The orchestrator routes correctly (re-dispatches on with-fixes, ticks the box on DONE)
- The agent doesn't ask the user "ready to proceed?" between tasks — continuous execution

### 5.5 Verify + finish

```
/llm-orchestrator:verify
```

**Pass:** agent runs the project's test command (or asks if none exists), reports a `Verify:` block with the actual command output.

```
/llm-orchestrator:finish
```

**Pass:** agent presents the 4-option menu (merge / push PR / keep / discard), recommends one based on the change shape, waits for user choice.

If all of 5.1–5.5 pass, the orchestration loop is sound. This is the most important phase.

---

## Phase 6 — BLOCKED recovery — 10 min

The 5-branch recovery tree is what makes this system recover on its own instead of stopping to ask. Test it — branch 5 is the one that stops and asks you, and it has to stay rare.

### 6.1 Force a BLOCKED → missing context

Set up a plan where task 2 references a file task 1 will create:

```
Create a plan for: (1) define a UserRole enum, then (2) add a function that returns the role's display label.
```

After `/llm-orchestrator:plan` and `/llm-orchestrator:dispatch`, watch task 2's implementer. It should return `BLOCKED` needing to see UserRole. The orchestrator should:
- Read the BLOCKED `Need:`
- Identify it as branch 1 (missing context) or branch 2 (waiting on sibling)
- Either paste task 1's output into task 2's envelope OR dispatch task 1 first
- Re-dispatch task 2 without asking the user

**Pass:** the user is not asked to intervene between the BLOCKED and the resolution. The orchestrator handles it.
**Fail:** the agent reports `Blocked:` to the user and stops — branch 5 (genuinely needs user) chosen when it shouldn't have been.

### 6.2 Force a BLOCKED → too large

Construct a task that's deliberately ambiguous: "Refactor the project."

**Pass:** implementer returns BLOCKED with `Need: smaller task`, orchestrator decomposes (branch 3) and dispatches a smaller chunk.

---

## Phase 7 — Continuation across sessions — 5 min

Cross-session continuity is Claude Code's native responsibility. Verify the native path works in your project.

While mid-orchestration on a plan (some tasks done, some pending), quit Claude Code.

In a new terminal in the same project:

```bash
claude --continue
```

**Pass:** the same session resumes with full conversation history. The plan file's `- [ ]` checkbox state is intact on disk (durable across sessions). Type:

```
Where did we leave off?
```

The agent reports the in-flight task and pending tasks — derived from the resumed conversation and the plan-file checkbox ticks.

Alternatively, in a fresh `claude` session, type `/resume` to pick a session from history.

---

## Phase 8 — Cleanup + assessment — 5 min

```bash
# Optional cleanup of test artifacts
rm -rf /tmp/orch-test-feature
# Inspect memory state
ls ~/.llm-orchestrator/memory/
ls ./CLAUDE.md
# Optional: clean up test memory
# rm -rf ~/.llm-orchestrator/memory/<hash>.md
# Edit ./CLAUDE.md to remove test entries
```

Score the test:

| Phase                    | Required for | Result |
|--------------------------|--------------|--------|
| 0. Pre-flight            | Any commit   |        |
| 1. Plugin install        | Smoke / Full |        |
| 2. Bootstrap             | Smoke / Full |        |
| 3. Response shape        | Smoke / Full |        |
| 4. Memory                | Full         |        |
| 5. Orchestration loop    | Full         |        |
| 6. BLOCKED recovery      | Full         |        |
| 7. /clear + resume       | Full         |        |

**Smoke pass:** phases 0–3 all green → safe to commit a minor change.
**Full pass:** all phases green → safe to publish a release.

---

## Common failure modes

| Symptom                                                | Likely cause                                         | Fix                                                                                          |
|--------------------------------------------------------|-------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| Statusline missing `prof:`                             | Plugin not loaded                                     | `/plugin enable llm-orchestrator`; restart session                                            |
| Agent replies in free prose, no shapes                 | SessionStart hook not firing or output not reaching context | Run the hook from terminal; check `additionalContext` has the meta-skill                      |
| `/llm-orchestrator:remember` says "with_lock: command not found"        | `scripts/lib/orch-lock.sh` not on the sourced path    | Verify install — should be at `$CLAUDE_PLUGIN_ROOT/scripts/lib/` or `<project>/.claude/scripts/lib/` |
| Hooks don't fire on a `--copy` install                 | `settings.json` missing the hook wiring               | Either install as plugin or hand-edit per `docs/install.md` "Wiring hooks"                    |
| Subagent dispatch produces free prose, no Status block | `orch-implementer.md` not discovered as an agent      | `/plugin list` should show the plugin enabled; check `agents/` directory exists in install path |
| `/llm-orchestrator:remember` writes to wrong file                       | Routing branch mis-fired (plugin-config vs user fact) | If fact starts with `research_aggressiveness:` or `declined_mcp:`, it goes to plugin memory by design; everything else goes to CLAUDE.md |
| Truncation in SessionStart output                      | Meta-skill > 8000 chars                               | Set `ORCH_SESSION_MAX_CHARS=16000` in shell env or `.claude/settings.json`                    |

---

## Reporting a bug

If a phase fails, capture:

1. The exact slash command or message that triggered the failure
2. The agent's reply (or absence thereof)
3. Output of the relevant hook from terminal:
   ```bash
   CLAUDE_PLUGIN_ROOT=~/.claude/llm-orchestrator bash ~/.claude/llm-orchestrator/scripts/hooks/<hook>.sh < /dev/null
   ```
4. `./tests/smoke.sh` output (to confirm it's a Claude Code-integration bug, not a mechanics bug)

File an issue using the `Found / Recommendation / Next` shape from the Concise Agent Protocol.
