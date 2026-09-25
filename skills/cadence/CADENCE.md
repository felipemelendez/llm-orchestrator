# The cadence — the full text

## Workflow selection

This skill is active only for an enabled project. Read its laws and `workflow`.
`proportional` uses this page and the short paths in `SKILL.md`. Any other
value, or none, is a configuration error that the scripts name with its
one-line fix (`"workflow": "proportional"`); correct it before working.
Project amendments and current user instructions take precedence.

Simple means a clear, reversible, local low-risk change: implement, inspect the
diff, run relevant existing checks, deliver. Standard adds acceptance criteria
and one independent reviewer. Neither needs a role pipeline, permanent
reports, worktrees, broad floors or mutation probes. Select by consequences and
uncertainty, not file/line counts. Writers may run tests and inspect their diff;
they cannot supply a required independent review or gate.

### Proportional Full path

1. Write or update the maintained specification when the change needs one.
   Independently review the contract and resolve material gaps before coding.
2. Implement with meaningful regression checks. Use isolation only where it
   protects concurrent work or is needed for probes; keep scopes bounded.
3. Obtain two fresh independent reviews with different briefs, neither seeing
   the other review or the implementer's conclusions. Honour requested providers.
   A provider dropout is not a completed review or permission to substitute.
4. Compare findings and record their disposition in the conversation/PR or
   temporary task evidence. Use a refuter only for substantive disagreement or
   a one-sided serious/catastrophic finding. Missing reviews are not agreement.
   Agreed findings still require resolution; do not create a third general review.
5. Fix material issues, verify affected fixes and independently assess the final
   change. Use the deterministic gate and targeted probes where they test the
   affected contracts; inspect individual outcomes, not merely its final exit.
   Unsupported checks remain explicit. Do not repeat valid checks for ceremony.
6. Deliver within the user's commit/push/merge scope. Retain useful spec/research/
   design/runbook updates. Finish task-owned temporary resources after consumers
   stop and deliverables are preserved; explain concrete preservation reasons.

The review briefs are [references/reviewer-spec.md](references/reviewer-spec.md),
[references/reviewer-plain.md](references/reviewer-plain.md) and
[references/refuter.md](references/refuter.md); read them for their lenses.
If repeated findings show the design is wrong, revisit the contract rather than
repeating the same review indefinitely.

### Evidence and temporary resources

Use the completion vocabulary in `SKILL.md`. An unfinished task keeps its
verification obligation across turns: a question, a pause or a commit that
changes no content does not clear it. Keep failures visible. Validation that is
required but unavailable stays PENDING or BLOCKED.

Nothing watches your commands. One Stop hook reads the transcript and warns
when a reply says PASS with no check behind it. That is the whole of it.

So run each check as one plain foreground command, and say PENDING when you have
not run one. The honesty is yours to supply; the hook only notices the obvious.

Use the task resource helper only when scratch or isolated trees are needed.
Resources and consumer leases belong to one task. Finish closes admission and
serializes with new consumers/resources. Stop hooks retry explicitly finished
tasks only. Preserve active/dirty/ignored-content/locked/unique work and unmerged
branches; never use force removal. A clean tree is removable only when its
commits remain reachable from a destination/ref retained by the whole cleanup.
Keep task state for recovery when cleanup cannot safely finish.

The commit and audit checks protect the rules and their numbered amendments;
they do not attest that reviewers ran. The lock below is binding. Evidence hook
enforcement also requires the harness's actual enablement and trust.

## The project files

| File | What it holds |
|---|---|
| `docs/llm-orchestrator/LAWS.md` | the constitution: mission, promises, harm ranking, rulings, standing constraints, model seats, the standard of work, the handoff law |
| `docs/llm-orchestrator/cadence.json` | the switch, the workflow, the runner profile, the path classes, `lock_extra` |
| `docs/llm-orchestrator/LOCK.sha256` | the manifest of locked content |
| `docs/llm-orchestrator/DESIGN_RULINGS.md` | design rulings, append-only, dated |
| `docs/llm-orchestrator/TRAPS.md` | traps and procedures learned, append-only, dated |
| `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh` | the git layer, versioned in the project |

Templates for the three markdown files: [references/laws.md](references/laws.md)
(with a filled-in [example](references/laws-example.md)),
[references/design-rulings.md](references/design-rulings.md),
[references/traps.md](references/traps.md). The hook text is
[references/commit-msg](references/commit-msg).

## The lock

The locked set is `docs/llm-orchestrator/LAWS.md`,
`docs/llm-orchestrator/cadence.json`, `.claude/settings.json`,
`.githooks/commit-msg`, `.githooks/orch-cadence-check.sh`, the FIRST `<!--
ORCH:LAWS:START -->` … `<!-- ORCH:LAWS:END -->` section of `CLAUDE.md` and
`AGENTS.md` (that pair only — the rest stays writable, so memory and onboarding
work; a second `START`, or one with no `END`, is named by the init and the lock
and refused at the commit, nothing refusing the edit itself, that being how a
locked one gets shadowed), plus `lock_extra`. The six FILES are held by the deny
rules, the marked section by the alarm alone (a rule addresses a whole file only),
and `LOCK.sha256`, which cannot record its own hash, by its deny rule.

**Two layers, in this order of trust.**

**Layer 1 — the native `Edit(...)` deny rules** in `.claude/settings.json`. The
primary: deny beats every hook and every allow rule at every scope. They cover the
built-in file tools, the recognised Bash file commands and every redirection
target, so the careless write fails here first. A project verifies once, in a live
session, what they cover on its machine; with Claude Code's sandbox enabled they
bind every subprocess too, and the plugin never enables it for anyone. What they
do not catch: a write from a subprocess where that sandbox is off.

**Layer 2 — the alarm**, the guarantee a change is seen: the end-of-turn verdict,
the session-start line, the git `commit-msg` hook and `--audit` in CI. It stops
nothing; it names a change after the fact — at the end of the turn, at the next
session start, at the commit where the hook is installed and not skipped, and in
CI through `--audit` when it was not. It never prevents a write.

**The boundary:** a careless write fails at once and loudly, but a write the deny
rules do not stop — a computed path, an archive, an interpreter, a script that
opens the file itself — happens, and layer 2 names it afterwards. The lock stops
accidental edits and makes deliberate ones visible in the history; it cannot stop
an agent determined to fake a ruling, since a script can rewrite `LAWS.md` and
`LOCK.sha256` together and commit a `Ruling <N>` message the hook accepts. A shell guard
that judged each command by its text was tried and removed; text matching cannot
be made tight, and the alarm already named what it caught.

An amendment is a commit that satisfies all three: its message carries
`Ruling <N>`, greater than the highest ruling number in the laws; the staged
`LAWS.md` records that ruling; and `LOCK.sha256` matches what is committed. The
person makes it with one command, `scripts/cadence-ruling.sh`, in their own
terminal.

**Proposing a change.** A seat that believes a protected rule is wrong keeps
working under it as written and explains why, in plain language. It writes the
change as a patch file outside Git (`git diff` of protected files only, adding
`Ruling <N>` to `LAWS.md`, where N is one more than the highest ruling there),
and shows the person the reason and the diff. If the person agrees, it gives
them the command, with this skill's absolute path:

```bash
bash <skill>/scripts/cadence-ruling.sh <patch-file> "<the person's wording>"
```

The command refuses a patch that touches a file outside the lock set (renames
and deletions included), changes `CLAUDE.md` or `AGENTS.md` outside the marked
section, no longer applies, or does not add `Ruling <N>` to `LAWS.md`; it also
refuses when `CLAUDECODE` or a Codex session variable is set, and the init's
deny rule `Bash(*cadence-ruling.sh*)` refuses it in Claude Code. It asks the
person to type `ruling <N>`, applies the patch, re-records the lock with
`--lock`, and commits `Ruling <N>: <wording>`; on any failure it undoes the
patch. It reads the confirmation from `/dev/tty`, and `--lock` rewrites an
existing lock only when a terminal is attached. An agent's shell has no
terminal, so both refuse there. The one known way around this is stated in
`docs/install.md`, "Changing the rules".

## The check script and the verdict line

`orch-cadence-check.sh` carries the modes `--verdict` (the session-start line),
`--lock` (rewrite `LOCK.sha256`; the plugin's own writer of it, and it rewrites an
existing lock only when a terminal is attached), `--commit-msg <msgfile>` (what
the git hook calls), `--audit <rev>` (the same check in CI, against a commit),
`--entries` (the lock set, one entry per line) and `--version`. It checks the
lock, the ruling and the workflow; it grades no review and cannot say whether
one ran.

**The verdict line** is what `--verdict` prints at session start, always beginning
`cadence:` — for example `cadence: LAWS.md (ruling <N>) · lock OK`. A project with
`LAWS.md` and no `cadence.json` sees `cadence: LAWS.md present, cadence.json
absent — run /llm-orchestrator:cadence-init`. If a session printed no such
line, the enforcement layer did not load; say so before anything else.

## The honest boundary

State this plainly wherever the cadence is described:

- Hooks and deny rules are **guardrails, not guarantees** — Anthropic's own
  framing, and it is right. A determined agent, a novel command spelling, or a
  harness that does not run hooks all defeat them.
- A native deny rule beats every hook and every allow rule at every scope: layer
  1, the deny rules, is the primary lock inside Claude Code; layer 2 — the
  verdict, the session line, the `commit-msg` hook and `--audit` — is the record
  that names what layer 1 let through, after the fact.
- The git `commit-msg` layer is what holds **across tools and in CI** — but
  only after `git config core.hooksPath .githooks` is run in each clone, and
  git's own skip flag steps past it, as do `cherry-pick` and `rebase` picks.
  `orch-cadence-check.sh --audit <rev>` in CI is the cross-tool backstop that
  catches what the hook did not see.
- An install that copies the plugin rather than loading it resolves hook helpers
  relative to the hook's own directory, not through a plugin-root variable that
  only the loaded form defines.
- Whether Codex fires hooks inside subagents is **unverified**. Treat the git
  layer as the enforcement there and the hooks as a convenience on trusted
  projects.
