# The cadence: what it rests on, and what is unverified

The cadence and its lock make claims about two harnesses — what a deny rule
covers, what a hook receives, where a skill is discovered, what blocks what. This
page records where each of those claims came from, so a reader can check the
source rather than trust the sentence. Everything here was read from primary
vendor documentation on the dates given, or executed on a real machine and
recorded.

Two things this page is not. It is not evidence that the *process* works — that
is field-record material, with its own honest limits, in
[`MEASUREMENTS.md`](./MEASUREMENTS.md). And it is not a promise: vendor
behaviour moves, and a claim verified on the date below can be false on the date
you read it.

## Claims and verdicts

| Claim the design rests on | Verdict | Source |
|---|---|---|
| Codex fires `PreToolUse` / `PostToolUse` / `SessionStart` / `SessionEnd` / `Stop` / `PreCompact` hooks, discovered from `hooks.json` or an inline `[hooks]` table beside an active config layer | VERIFIED | <https://learn.chatgpt.com/docs/hooks> |
| A Codex `PreToolUse` payload carries `tool_name` and `tool_input.command` and **no** `file_path`; a file edit arrives as an `apply_patch` patch body inside the command | VERIFIED | <https://learn.chatgpt.com/docs/hooks> |
| A Codex hook denies with exit 2 plus a stderr reason, or with `hookSpecificOutput.permissionDecision: "deny"` | VERIFIED | <https://learn.chatgpt.com/docs/hooks> |
| Project-local Codex hooks load only when that project's `.codex/` layer is trusted | VERIFIED | <https://learn.chatgpt.com/docs/hooks> |
| Codex discovers skills at `.agents/skills` (repo, upward to the root), `$HOME/.agents/skills`, `/etc/codex/skills` — **not** `.codex/skills` — and follows symlinked skill folders | VERIFIED (the "Codex may not follow a symlink" premise was contradicted; a copy is a choice, not a requirement) | <https://learn.chatgpt.com/docs/build-skills> · <https://agentskills.io/specification> |
| A skill's `name` must be lowercase, ≤ 64 characters and match its folder name; `description` is required; `license` and `compatibility` are shared spec fields both harnesses accept | VERIFIED | <https://agentskills.io/specification> |
| The global Codex instruction file is `~/.codex/AGENTS.md`, concatenated root-down under a **combined** 32 KiB budget (`project_doc_max_bytes`) | VERIFIED — the reason the rendered block is capped at 2 KiB: an oversized global block starves the project's own file | <https://learn.chatgpt.com/docs/agent-configuration/agents-md> |
| `CLAUDE.md` imports with `@path`, relative to the importing file, four hops deep, and import parsing skips code spans and fences; `@AGENTS.md` on the first line is the documented recipe | VERIFIED | <https://code.claude.com/docs/en/memory> |
| Claude Code hooks run inside subagents; tool events fire the same configured hooks and carry `agent_id` / `agent_type` | VERIFIED | <https://code.claude.com/docs/en/hooks> · <https://code.claude.com/docs/en/sub-agents> |
| The subagent tool's canonical name is `Agent` (`Task` is the pre-2.1.63 alias); hook matchers match canonical names only | VERIFIED | <https://code.claude.com/docs/en/sub-agents> |
| No native rule can require a *present* parameter: `Agent(model:*)` does not match a call that omits `model`, so the dispatch-model check must be a hook | VERIFIED | <https://code.claude.com/docs/en/permissions> |
| Permission rules evaluate deny, then ask, then allow; a hook decision does not bypass them; a deny at any level cannot be re-allowed at another | VERIFIED | <https://code.claude.com/docs/en/permissions> |
| A path lock must be spelled `Edit(path)`: rules written for `Write`, `NotebookEdit`, `Glob` or the legacy `MultiEdit` are accepted, never consulted, and warned about at startup | VERIFIED | <https://code.claude.com/docs/en/permissions> |
| `deny` and `ask` rules in a project settings file apply without the workspace-trust dialog, since they only restrict | VERIFIED — and the reason the deny rules ship only into a project that ran the init | <https://code.claude.com/docs/en/permissions> |
| Plugin layout: `.claude-plugin/plugin.json`, `skills/<name>/SKILL.md`, `hooks/hooks.json`; `${CLAUDE_SKILL_DIR}` is the variable available to a skill (`${CLAUDE_PLUGIN_ROOT}` is plugin-scoped), and neither expands in Codex | VERIFIED — the reason `SKILL.md` prints both the expanded and the relative spelling | <https://code.claude.com/docs/en/plugins-reference> |
| Codex protects `.agents/`, `.codex/` and `.git` as read-only inside a writable root, recursively; it has no native path-deny for an arbitrary file | VERIFIED — the reason the git layer, not a directory, is the cross-tool protection | <https://learn.chatgpt.com/docs/agent-approvals-security> |
| An `Edit(path)` deny rule covers the built-in file tools, the Bash file commands Claude Code recognises (`cat`, `head`, `tail`, `sed`) and every Bash redirection target, in every permission mode; it does **not** cover a subprocess that opens the file itself | VERIFIED, read 2026-09-06 | <https://code.claude.com/docs/en/permissions> and <https://code.claude.com/docs/en/permission-modes> (the modes, bypass included) |
| With the sandbox enabled, `Edit` deny rules merge into an OS-level deny-write list enforced for every subprocess | VERIFIED, read 2026-09-06 — the plugin never enables the sandbox for anyone | <https://code.claude.com/docs/en/sandboxing> (and the settings reference's `sandbox.filesystem`) |

Everything in the table above was read from these pages, the Claude Code set on
2026-09-05 and the two permissions rows re-read on 2026-09-06:

- <https://code.claude.com/docs/en/memory>
- <https://code.claude.com/docs/en/hooks>
- <https://code.claude.com/docs/en/permissions>
- <https://code.claude.com/docs/en/permission-modes>
- <https://code.claude.com/docs/en/sandboxing>
- the Claude Code settings reference (the `sandbox.filesystem` section)
- <https://code.claude.com/docs/en/sub-agents>
- <https://code.claude.com/docs/en/skills>
- <https://code.claude.com/docs/en/plugins-reference>
- <https://code.claude.com/docs/en/tools-reference>
- <https://learn.chatgpt.com/docs/hooks>
- <https://learn.chatgpt.com/docs/build-skills>
- <https://learn.chatgpt.com/docs/agent-configuration/agents-md>
- <https://learn.chatgpt.com/docs/agent-approvals-security>
- <https://agentskills.io/specification>

## Unverified, and left that way

- **Whether a Codex `PreToolUse` hook fires inside a Codex subagent.** The docs
  name only `Interrupt` and `SessionEnd` as not running for subagents, so it is
  implied by an exception list and never stated. Treat the git layer as the
  enforcement there and the Codex hook as a convenience on a trusted project.
- **Whether a Codex hook matcher can select on a patch's target path.** No path
  field is documented on the payload — only `tool_input.command` — so the adapter
  scans the patch text instead of matching a path.

## The live check of the deny rules

The claim that matters most is the one the lock's first layer rests on, so it was
executed rather than only read. Recorded 2026-09-06, Claude Code 2.1.263.

**Method.** A throwaway git project containing the five `Edit(...)` deny rules
`cadence-init` writes, in `.claude/settings.json`, and a `LAWS.md` with one ruling
line. Six headless sessions (`claude -p`, a small model, `--allowedTools` granting
the tool under test, four turns each), one write per session. No plugin loaded.
The file's hash was compared before and after each session, and the tool's own
response recorded.

| write attempted | result | file after |
|---|---|---|
| the Edit tool on the locked file | refused: "File is in a directory that is denied by your permission settings." | unchanged |
| the Write tool, overwriting it | refused, same message | unchanged |
| Bash `echo REWRITTEN > <locked file>` | denied by the permission system; never executed | unchanged |
| Bash `cp notes.md <locked file>` | denied by the permission system; never executed | unchanged |
| Bash `sed -i '' s/process/PROCESS/ <locked file>` | denied by the permission system; never executed | unchanged |
| control: the Edit tool on an ordinary, undenied file | "has been updated successfully" | changed |

**What it shows.** Layer 1 fired on every path tried, including `cp`, which is
more than the documentation promises — the page names the recognised file
commands and the redirection targets, not every copy verb. The control edit
succeeded, so the five refusals are the deny rules doing their job and not a
blanket denial of everything.

**What it does not show.** The sandbox was not enabled on that machine, so the
OS-level enforcement in the last row of the table above is documented and not
executed here. And no case was run for a subprocess that opens the file without
naming it on the command line (a script that opens it, a formatter run over a
whole directory) — that is precisely the case the sandbox is claimed to close,
and it remains unmeasured.

**Repeat it once on your own machine.** The check is about ten minutes: write the
deny rules, try one Edit, one redirection and one `cp` at a locked path, and
confirm a control edit elsewhere still goes through. Vendor behaviour moves, and
this layer is the only one that stops anything before the fact.

## The boundary

A write the deny rules do not stop happens. It is named at the end of that turn
by the verdict, again at the next session start, and refused at the commit by the
`commit-msg` hook — or by `orch-cadence-check.sh --audit <rev>` in CI, for the
clone where the hook was never routed. Hooks and deny rules are guardrails, not
guarantees.
