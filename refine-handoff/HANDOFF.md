# Handoff: llm-orchestrator refinement (2026-09-25)

Read this whole file before doing anything. It is the state of the work, the
process, and the rules. The owner is Felipe; address him as "Captain".

> **This folder must not reach `main`.** `refine-handoff/` is working material.
> Delete the whole folder, in its own commit on `refine/integration`, before
> Felipe merges PR #34. PR #34's checklist and ticket T12 both say so. Run
> `git ls-tree -r --name-only origin/refine/integration | grep '^refine-handoff/'`
> before handing PR #34 to Felipe; it must print nothing.

## 1. What we are building

Felipe's plugin, `github.com/felipemelendez/llm-orchestrator`, for Claude Code
and Codex. The goal is a system that is light for simple questions and
reliable for long, complex projects, with nothing unused or legacy left in it.
Felipe is the only user; nothing old is kept for compatibility.

- `plans/2026-09-25-assessment.md`: why each change is being made.
- `plans/2026-09-25-tickets.md`: every ticket, the rules for every ticket, the
  order, and the decisions. **This is the working plan.**
- `research/`: what Anthropic, OpenAI and published papers say (2026-09-25).
  Leads, not proof: confirm a claim before building on it.
- `reviews/`: GPT reviews still waiting to be fixed (T5, T20).
- The approved review design is committed at `docs/specs/review-design.md`.

On this machine the plan and research files lived in gitignored folders
(`docs/llm-orchestrator/plans/`, `.../research/`); here they are committed
copies. Keep working from these copies and update them as you go.

## 2. Where the work is

- Repo: `https://github.com/felipemelendez/llm-orchestrator` (public).
- `refine/integration`: the staging branch. Every ticket lands here through
  its own PR (#21–#33 so far).
- PR #34 (draft): `refine/integration` → `main`. **Only Felipe merges it.**
  Update its description as tickets land (fetch the live body first, then
  change it minimally).
- Ticket branches: `refine/t<N>-<slug>`, cut from `refine/integration`. On a
  new machine, clone the repo and use `git worktree add ../llm-orchestrator-wt/<slug> origin/refine/<branch>` per ticket.

## 3. State of every ticket

Merged into `refine/integration`: T1, T3, T4 (spec), T7, T8, T10, T13, T14,
T15, T16, T17, T18, T19, T21 (PRs #21–#33 and #35).

Dropped by Felipe: T2 (no notice shown to him; the check tells the agent only)
and T9 (commands stay commands).

**Last known state when the old machine stopped (2026-09-25, evening):**
- T5 `refine/t5-review-build` head `764fb91`: round 2 found one last
  catastrophic item (a quote could drop a real bug); the fix removes
  quote-based drops, and `764fb91` ("Drop a finding only on a passing receipt
  1…") appears to contain it — confirm. A live Full review with the sandbox
  was running (`~/.local/state/llm-orchestrator/reviews/…-live2` on the old
  machine; not portable) — **rerun one live Full review** on the new machine.
  Then a short confirmation by both reviewers, `run-all.sh`, PR, merge.
- T20 `refine/t20-ruling-command` head `11acdcf` (integration merged in
  locally; push may be one merge behind): both reviewers' round 2 items are
  fixed; the Opus reviewer found nothing serious left. Remaining: merge
  `origin/refine/integration`, `run-all.sh`, PR, merge.
- T6 `refine/t6-remove-legacy` head `10c9a50` is a **WIP commit saved by the
  coordinator**: partial, not reviewed, tests not run. Read its diff, finish
  the ticket, then Full review.

In progress (each on its branch; check its latest pushed commit first, since
the agent may have pushed more after this file was written):

- **T5, build the review system** (`refine/t5-review-build`, last commit
  `1df09b3` or later). Built and working. Round 1 of the Full review (GPT
  adversarial in `reviews/t5-adversarial-report.md`, plus an Opus contract
  review) found 8 + about 20 issues; **all are fixed**, each with a test that
  failed first (test-review went from 68 to 94 tests). Highlights: Claude
  seats now run inside Claude Code's Bash sandbox with a reduced environment;
  clones use `--no-hardlinks`; any missing run file gives INCOMPLETE; the run
  directory may not be in a temp dir; a repo with submodules gives INCOMPLETE.
  Next:
  1. Round 2 of the Full review: the same two kinds of reviewer (fresh Opus
     contract, GPT adversarial via the command in section 4), scoped to what
     changed and to realistic cases.
  2. One live Full review on a planted bug with the new sandbox and reduced
     environment (the only live run so far predates them); show the result.
  3. `bash tests/run-all.sh </dev/null`, PR into `refine/integration`, merge.
  Known limits recorded in the spec: the GPT seat can read (not write) the
  run directory; the Claude sandbox on Linux is unverified; a Claude seat that
  needs Bedrock/Vertex credentials drops out. Ruling 4 text (remove
  `workflows/` from LAWS and cadence.json) must go into the combined ruling
  (section 7). `skills/cadence/references/refuter.md:59` is left for T6.
- **T20, the rule-change command** (`refine/t20-ruling-command`, head
  `ab0f30b` or later). `skills/cadence/scripts/cadence-ruling.sh <patch>
  "<wording>"`, run by Felipe in his own terminal. Round 1 of the Full review
  (GPT report in `reviews/t20-adversarial-report.md`, plus Opus) found 11
  issues; **all are fixed** (`run-all.sh`: 45 suites pass). Highlights: it
  applies a private copy of the patch and shows its hash; rename/copy headers
  and changes outside the protected set are refused; any failure or
  interruption undoes everything, including a landed commit; it runs
  `--audit HEAD` after committing; old projects get a ready-made upgrade
  ruling patch from cadence-init; it refuses inside Claude Code or Codex
  sessions (the Codex variable names are unverified); cadence-init writes a
  `Bash(*cadence-ruling.sh*)` deny rule; the docs say plainly what the lock
  cannot stop. The test file is now `tests/test-ruling-command.sh`.
  Next: round 2 of the Full review (fresh Opus contract + GPT adversarial,
  scoped to the fixes and realistic cases), then PR and merge.
  The regenerated protected-file patch is `reviews/t20-ruling-4.patch`; fold
  it into the combined ruling (section 7).
  - **Decided (Felipe, 2026-09-25): no signing.** The plugin is for everyone
    and must not depend on any one person's tools. The lock stops accidental
    rule changes, every change shows in the history, and the docs say plainly
    what the lock cannot stop (item 11). Do not ask about signing again.
- **T10 is merged** (PR #35). The smallest run that answers "does Full beat
  /code-review" is `run --arms full,code-review` on all 83 cases, about
  **$55–$250**, and needs T5 merged first; see `tests/evals/README.md` (pilot
  step first). Bring Felipe that price after T5 merges. **Never run paid
  evals yourself.**

Not started (in order):
- **T6**, remove the legacy procedure: **started** on `refine/t6-remove-legacy`
  (check its latest commit). It avoids the sections T5 and T20 edit; merge
  their branches into it after they land, then Full review (two reviewers). Also fixes the "printed as your final message"
  wording T18's review found, and `skills/cadence/references/refuter.md:59`.
- **T12**, remove everything unused. Runs on the finished tree. Its ticket
  lists known items (stale hooks text in `docs/anthropic-ecosystem.md`; the
  `session-start.sh` stdin hang; add `scripts/lib/orch-subagent-report.py`
  and `cadence-ruling.sh` to `install.sh --check`; two tests that fail under
  machine load). **Also delete `refine-handoff/`.**
- **T11**, release notes and version. Last.

## 4. How the work is run

For each ticket:
1. One agent with a fresh context does it, in its own worktree on its own
   branch cut from `refine/integration`, and pushes. It does not open the PR.
2. The coordinator (you) reads the diff and gets fresh reviewers by path
   (the repo's laws, `docs/llm-orchestrator/LAWS.md`):
   - Simple: coordinator review only.
   - Standard: one fresh Opus reviewer that never saw the author's report.
   - Full (two hubs, the lock, verification or review contracts): two blind
     reviewers with different briefs, never seeing each other's findings: an
     Opus contract reviewer (checks against the ticket or spec) and a GPT
     adversarial reviewer through Codex (plain-language scene, tries to make
     the wrong thing happen). A refuter only if they disagree or one alone
     reports something serious.
3. Send every finding back to the same author agent at once (it keeps its
   context). Fix clear defects without asking Felipe. Scope later review
   rounds to what an honest agent would really do; stop chasing contrived
   cases and write them down as known limits instead.
4. Merge `origin/refine/integration` into the branch, run
   `bash tests/run-all.sh </dev/null` (about 15–20 minutes), then open the PR
   into `refine/integration` with a plain description and merge it.
5. Run independent tickets in parallel; only wait where two tickets edit the
   same files.

The GPT reviewer command (Codex CLI 0.157.0, logged in with ChatGPT; its
default model is `gpt-6-astra`). Build the list of switched-off MCP servers as
an array; in zsh a plain string is passed as one argument and breaks the call:

```bash
C=$(command -v codex)   # on the old machine: ~/.local/share/mise/installs/node/24.18.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
OFF=(); for n in $(grep -oE '^\[mcp_servers\.[^].]+' ~/.codex/config.toml | sed 's/\[mcp_servers\.//' | sort -u); do OFF+=(-c "mcp_servers.$n.enabled=false"); done
"$C" exec -s read-only -c model_reasoning_effort=high "${OFF[@]}" --disable apps --disable plugins \
  -C <worktree> -o <report.md> "$(cat <brief.md>)" < /dev/null > <log> 2>&1
```

Always close input with `</dev/null` when running tests or `codex exec` from
a tool; without it a hook or Codex waits forever for input.

## 5. Rules and standards (Felipe's)

- The plugin is for a public audience: never design around Felipe's own
  machine or tools (e.g. a password manager).
- Talk to Felipe in plain, short language, with no jargon; lead with the
  answer; give a recommendation when he must decide. Address him as "Captain".
- Commit, branch, push and PR as needed. **Never merge into `main`.**
- The work must be excellent: tests first (confirm they fail before the fix),
  no new hooks, nothing unused or legacy left behind, docs updated in the same
  change, no dated counts or machine-specific numbers in shipped docs.
- Never edit protected files (`docs/llm-orchestrator/LAWS.md`, `cadence.json`,
  `LOCK.sha256`, `.claude/settings.json`, `.githooks/`). Write the exact
  proposed change for Felipe instead.
- Never run paid evaluations. Small live `claude -p` / `codex exec` probes to
  confirm behavior are fine; keep them tiny.
- Verify before claiming: agents' reports, research files and comments are
  leads until checked in code, docs or a live run.
- One-line commit messages. PR bodies end with the Claude Code line.
- Reviewers: Claude on the latest Opus (`opus`), GPT on the Codex CLI default,
  reviewer effort high. The explorer agent is on `sonnet`.

## 6. Decisions already made (do not re-ask)

- Keep the rulebook lock. Rule changes: the agent explains why; if Felipe
  agrees, he runs one command (T20). No commit signing.
- Keep the destructive-git guard, the no-verify guard and the lock; the
  dispatch-model, config-protection and unlock guards go (T19 done; T20 removes
  the unlock guard).
- Review design (T4) approved with all seven decisions: one Python script; the
  refuter runs on every serious finding; the refuter is always Claude Opus; the
  GPT reviewer may write in its own copy; review history stays outside the
  repo; security is a lens in both reviewers' briefs; Claude reviewers use
  `opus`.
- Codex: one install route (the plugin installs skills and hooks;
  `install.sh --codex` only writes the instructions block). Done in T21.
- No legacy workflow survives.

## 7. The end

1. After T5, T20, T10, T6 and T12 land, build **one combined ruling patch**
   with everything that needs a ruling, and give Felipe the one
   `cadence-ruling.sh` command to run:
   - the Ruling 3 amendment (text in T21's PR #29 and its report; latest
     version says `install.sh --codex` removes old entries "once the plugin is
     installed");
   - Ruling 4, removing `workflows/` from LAWS.md section 2 and from
     `cadence.json` `src_roots` and `prod_globs` (from T5);
   - T20's own protected changes (LAWS intro and standing order, the AGENTS.md
     marked block, the new `.githooks` copies), a first version is
     `reviews/t20-ruling-4.patch`; regenerate it from the final T20 branch.
   Number the rulings from the next free number at HEAD.
2. Refresh the installed plugin copy to match the source (a standing rule in
   LAWS section 2), wherever Felipe has it installed.
3. T11 release notes and version.
4. Delete `refine-handoff/`, confirm it is gone from `refine/integration`,
   mark PR #34 ready, and tell Felipe his three steps: run the ruling command,
   try the Codex checks in a real Codex session, review and merge PR #34.
