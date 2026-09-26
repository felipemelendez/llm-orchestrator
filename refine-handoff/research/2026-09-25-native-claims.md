# T8: claims about native Claude Code features, checked 2026-09-25

Checked against Claude Code v2.1.282 (installed locally), the docs at
code.claude.com/docs read on 2026-09-25, and runs in a scratch repository
(`mktemp` directory under the session scratchpad: a bare remote with one
commit on `main`, a local `feature` branch one commit ahead, and an untracked
file). Runs used `claude -p --model sonnet`. Nothing new was adopted.

## 1. Can the agent run `/code-review` itself?

- **Plugin said:** no. `docs/anthropic-ecosystem.md` said native review
  "cannot be model-invoked (v2.1.215)"; `skills/requesting-code-review/SKILL.md`
  says it carries `disable-model-invocation: true`.
- **True:** yes. The docs say "Claude can start `/code-review` on its own".
  Before v2.1.246 it depended on a feature flag fetched from Anthropic; v2.1.246 removed that dependency. A person can turn it off
  with `skillOverrides: {"code-review": "user-invocable-only"}`. It runs as a
  background subagent in an interactive session and in the foreground under
  `-p`. `/verify` is still user-only (since v2.1.215); `/deep-research` is
  user-only since v2.1.218.
- **How checked:** <https://code.claude.com/docs/en/code-review#let-claude-start-the-review>
  and <https://code.claude.com/docs/en/commands>. One scratch run: after
  committing a file with an off-by-one bug, the prompt "Review the code
  changes on this branch for bugs." made the model call `Skill` with
  `code-review`, which found the bug and reported through `ReportFindings`.
- **Recommendation:** README and `anthropic-ecosystem.md` now say this.
  `skills/requesting-code-review/SKILL.md` lines 17–19 are still wrong; that
  file belongs to the T4/T5 review rewrite, so fix it there. T4 can now
  consider `/code-review` as one reviewer (Felipe decides).

## 2. Which commit does native `isolation: worktree` branch from?

- **Plugin said:** the default branch, not `HEAD`, unless
  `worktree.baseRef: "head"`, which a plugin cannot set. `anthropic-ecosystem.md`
  also said "Prefer native isolation for the checkout itself", which
  contradicted `skills/using-git-worktrees/SKILL.md`.
- **True:** the default (`"fresh"`) branches from the remote's default branch
  (`origin/HEAD`, fetched if older than 24 hours). With no remote, or no
  `origin/HEAD`, it falls back to the local `HEAD`. `"head"` branches from the
  local `HEAD` and carries committed work only. A plugin's `settings.json`
  applies only `agent` and `subagentStatusLine`; other keys are dropped.
- **How checked:** <https://code.claude.com/docs/en/worktrees#choose-the-base-branch>,
  <https://code.claude.com/docs/en/sub-agents> (the `isolation` field),
  <https://code.claude.com/docs/en/plugins-reference> (`settings`). Three
  scratch runs with a project agent that has `isolation: worktree` and prints
  `git log`:
  - default: started at the remote `main` commit, no local commit, no
    untracked file;
  - `--settings '{"worktree":{"baseRef":"head"}}'`: started at the local
    `feature` commit, no untracked file;
  - a test plugin (`--plugin-dir`) whose `settings.json` set
    `baseRef: "head"`: started at the remote `main` commit, so the plugin
    setting was ignored.
- **Recommendation:** keep the plugin's own worktree scripts
  (`orch-worktree-materialize.sh` cuts from `HEAD`) and the green-baseline
  capture; nothing native replaces them. Docs fixed: README table,
  `anthropic-ecosystem.md` worktree row, two new rows in
  `docs/cadence-evidence.md`. The skill texts (`using-git-worktrees`,
  `using-workflows`) were already right.

## 3. Would `skills:`, `memory:` or `context: fork` remove text an agent reads?

What agents read today: each agent's own body, plus an envelope the controller
fills from `templates/*-prompt.md` (106 to 166 lines each), with CLAUDE.md
sections pasted as content. No agent reads a skill file.

- **`skills:` (preload).** Injects the full text of each listed skill at
  start. It cannot preload a skill with `disable-model-invocation: true`.
  Because agents read no skills now, preloading would add text, not remove
  it: for example, `test-driven-development` (50 lines) in place of
  `orch-implementer`'s one-line "Follow TDD" rule. The templates are not
  skills, so `skills:` cannot carry them. **Recommendation: do not adopt.**
- **`memory:` (per-agent memory).** Adds memory instructions and up to 200
  lines / 25 KB of the agent's `MEMORY.md`, and automatically gives the agent
  Read, Write and Edit. It does nothing when auto memory is off. It adds text,
  and for the read-only agents (explorer, reviewers, researcher, debugger)
  it would give them write tools they must not have. **Recommendation: do not
  adopt.**
- **`context: fork` (skill runs as a subagent).** The skill text becomes the
  subagent's prompt and never enters the main conversation, so it would remove
  that text from the controller's context. Limits: the subagent does not see
  the conversation, runs in the background by default (so it gets the narrow
  background tool set), and waits under `-p`. Possible fit: commands that only
  start one agent, such as `/llm-orchestrator:research` or the study step of
  `/llm-orchestrator:onboard`. **Recommendation: look at this with T9
  (commands to skills), measure the context saved, and adopt only with
  Felipe's approval.**
- **Also found, `omitClaudeMd` (v2.1.271).** Starts an agent without the
  user, project and local CLAUDE.md files. The controller already pastes the
  relevant CLAUDE.md sections into the envelope, so the agent may read the
  same text twice. This is the one field that would remove text. Risk: rules
  in CLAUDE.md that the controller does not paste would no longer reach the
  agent. **Recommendation: candidate for Felipe; measure on the implementer
  and reviewers before adopting.**

Docs: README "Memory" row and `anthropic-ecosystem.md` say the plugin does not
use `memory:` and why. Nothing else changed.

## 4. Cited papers

`docs/cadence-evidence.md` cites no papers; it cites only vendor docs. The
papers are in the README "Grounding" paragraph and `docs/anthropic-ecosystem.md`.
Each abstract page (and the HTML table where numbers were cited) was read on
2026-09-25.

| Paper | Plugin said | True | Newer result | Fix |
|---|---|---|---|---|
| arXiv:2606.08529, Scaffold Effects on GAIA (Starace, v1 2026-06-07, one author, preprint) | "20+ points even on frontier Anthropic models" | Up to 28 points within one model (Opus 4.7, Level 2); the most capable Anthropic model gained the most from structured scaffolds at Level 2 | arXiv:2607.22585 (coding, Terminal-Bench Pro): harness moved pass rates by 0–8 points but tokens per solved task by up to 40x. It adds to the claim rather than replacing it | README states the 28-point figure at the harder level, calls it a single-author v1 preprint, and adds the coding result as another study |
| arXiv:2503.13657, MAST (v3 2025-10-26, NeurIPS 2025 Datasets and Benchmarks) | "incorrect or absent verification is a leading cause"; step repetition 15.7%, N=1642 | Task verification is one of three categories; no or incomplete verification 8.2% and incorrect verification 9.1% (17.3% together); step repetition 15.7%, not recognising completion 12.4%, premature termination 6.2%, 1,642 traces. All hold in v3 | None found | README gives the 17.3% figure (no venue label); ARCHITECTURE and `anthropic-ecosystem.md` numbers unchanged (they match) |
| arXiv:2603.00539, Are LLMs Reliable Code Reviewers? (Jin and Chen, v1 2026-02-28) | LLMs over-flag correct code; asking for explanations and fixes makes it worse; fix-guided filter uses the fix as executable counterfactual evidence | All three are in the abstract | None found (the literature research also found none) | No change. The README sentence about `workflows/review-diff.js` implementing it is left for T5 |
| Anthropic, Building Effective Agents (2024-12-19) | "duplicated mechanics are a liability as the platform absorbs them" | The article does not say this. It says to add complexity only when it demonstrably improves outcomes, and that frameworks add abstraction layers that obscure prompts | n/a | README now cites what it says |
| arXiv:2606.21811, Steer, Don't Solve (v2 2026-09-01) | Table 1: weak critic 0.0/−0.2/+0.8, frontier critic +17.4 to +22.2; trained 8B +3.0–5.2 at 30–92x lower cost | Those are v1 numbers. v2 Table 1: untrained 4B/8B critic +0.2 to +1.4 on three of six agents, −3.6, +3.8 and +8.2 on the others; Opus 4.6 critic +18.0 and +18.2 (two agents); trained critics +2.6 to +16.0; on the two Qwen agents the 8B SFT critic gives 5.2–6.0x lower total cost than the Opus critic (Fig. 4, Sec. 3.4) | v2 replaces v1 | `anthropic-ecosystem.md` uses the v2 numbers. The conclusion (an untrained small critic adds little) still holds, but less cleanly: one agent gained 8.2 points from an untrained 4B critic |
| HAL, arXiv:2510.11977 (ICLR 2026) | 21,730 rollouts; more effort gave equal or lower accuracy in 21 of 36 settings | Same | None found | Link added; wording is "equal or lower accuracy", no venue label |

## Completion check wording (T2 note)

README said the check "says so on screen" and "is called out on screen", and
that it "prints a line". It tells the agent only. All four places now say the
note goes to the agent and nothing is shown to the person. ARCHITECTURE.md
already said "nothing is printed for the person" (Layer 7) and "the person sees
nothing" (Codex), so it needed no change.

## Codex (one line)

Codex has a native reviewer (`/review`, `codex review`), so `docs/codex.md`'s
"the reviewers ... stay in Claude Code" is a choice, not a limit of Codex.
Not changed here; it belongs to the T4/T5 review design.

## Not fixed, outside T8

`docs/anthropic-ecosystem.md` "Hooks" section describes hooks that are not in
`hooks/hooks.json` (an evidence ledger, a protocol grader, PostToolUseFailure,
"sixteen hook scripts across seven events"), and "What we deliberately don't
use" still describes the evidence ledger. The "Task tools" section is T13's.
