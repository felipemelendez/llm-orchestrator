# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

A correctness and attention pass. The trigger was a reviewer subagent that saw
`[orch-evidence <hash> exit=0] (cite this line in your Verify: block)` appended
to a grep result, correctly refused to obey an imperative arriving through a
data channel, and escalated it. Chasing that one report surfaced a cluster of
hooks that were dead, firing falsely, or talking to agents that had no idea what
they were being told.

The through-line: **a mechanism that is wrong, or that speaks when it knows
nothing, costs more than one that does not exist** — it trains agents to
discount the channel it shares with the accurate signals.

### Fixed — mechanisms that were silently dead

- **`orch_extract_last_assistant_text` read the wrong key.** Real transcripts
  nest assistant content under `message.content`; it read top-level `content`.
  Measured against a live transcript: 0 entries with top-level content, 538 with
  nested. Every consumer bailed at its `[[ -n "${REPLY}" ]] || exit 0` guard, so
  the **protocol grader, the verify gate, and the retry cap's Stop path had never
  once fired**. A gate that always passes is indistinguishable from a gate that
  never trips, which is why this survived. Sidechain (subagent) entries are now
  skipped so the controller's Stop event is not graded against a subagent's reply.
- **`orch-researcher-validator.sh` filtered on `subagent_type`.** The field is
  `agent_type`, and plugin values are namespaced (`llm-orchestrator:orch-researcher`).
  All 264 lines, plus the brief-index write enforcement, were unreachable.
- **The evidence ledger ignored every multi-line command.** The verify-command
  regex anchors on `(^|[;&|])` but was compiled without `re.MULTILINE`, so `^`
  matched only offset 0 and a newline is not in that class. `cd /tmp && npm test`
  recorded a row; the identical two-line form recorded nothing.
- **The research gate never saw past line one.** The prompt was grepped out of
  the event JSON and never decoded, so a newline stayed as the characters `\` and
  `n` — and `n` is a word character, which kills the `\b` in every signal pattern.
  Multi-line prompts, the normal shape of a spec, bypassed the gate entirely.

### Fixed — mechanisms that were wrong

- **The worktree reaper released a live sibling's writer mutex.** It reaped every
  `.worktrees/<slug>` mentioned anywhere in a success-shaped final message, so a
  `DONE` saying "I left `.worktrees/sibling` alone, another implementer is still
  writing there" unlocked the sibling — two writers in one tree, the exact
  corruption the mutex prevents — then bailed via its first-success `exit 0` with
  its own mutex still held. Ownership now comes from evidence only: the agent's
  own CWD, or a single unambiguous mention. Anything else reports and refuses.
- **The destructive-git guard was disarmed by a co-occurring `-b`.** The
  `checkout -b` / `switch -c` creation exception was tested against the whole
  compound command, so `git checkout -b tmp && git checkout main` was **allowed**
  — and a branch switch overwrites every differing tracked file. Even
  `echo 'git checkout -b x'; git checkout main` passed, lending a flag from
  inside a quoted string. The rule is now evaluated per shell segment.
- **Both PreToolUse guards scanned the raw payload.** `grep -rn -- '--no-verify'
  scripts/` — a read-only search, and the likeliest benign hit a guard will ever
  see — was hard-blocked, as was a clean `git commit` whose model-written
  `description` field mentioned the flag. They now decode `tool_input.command`
  and treat quoted text as the argument it is, except where the command can
  re-enter a shell (`bash -c`, `eval`, `$(...)`), which still blocks. Every
  fallback is toward blocking.
- **The verify gate rejected the protocol's own canonical shape.** It required
  `Verify:` content on the same line; the protocol writes it both ways. Its first
  live firing after the extractor fix was a false positive on a correct reply.
  `orch_has_section` now accepts either form, and a `Changed:` quoted inside a
  code fence no longer trips the gate against itself.
- **`ORCH_SIG_VERSION` fired on any decimal.** "add a null check to line 3.2" and
  "replace the 2.5 second timeout" both compelled a research detour. Ordinal
  nouns and unit suffixes are now erased before the version test — written
  without `\b`, which BSD sed does not support and silently ignored.
- **Bare `npm` compelled research.** The subcommand group was optional, so
  `npm test` triggered a full classifier round trip.

### Removed — channels that were wrong more often than right

- **`RESEARCH_UNCERTAIN` notices.** The "structural hint" list included `api`,
  `cli`, `plugin`, `module`, `server` — words in most engineering requests — and
  the library name was the first capitalized token not on a stop list. Measured:
  *possible library **Felipe***, ***Bash***, ***CLI***, ***Monday***, ***API***.
  Its own code comment promised that plain proper nouns "must NOT fire." Every
  one did. Confident signals still fire; guesses no longer speak.
- **The `[orch-evidence ...]` marker, by default.** It rewrote Bash stdout, and
  when `tool_response` carried no literal `stdout` string it **replaced the
  command's real output with the marker alone**. Its parenthetical was an
  instruction in a data channel, which well-behaved agents correctly refuse — the
  mechanism selected against its own adoption. And it reached all seven agents
  while only the implementer's prompt explained it. The hook is now append-only
  and cannot touch tool output; `ORCH_EVIDENCE_MARKER=1` restores an inert
  marker for cross-agent transport.
- **The "Red flags — thoughts that mean STOP" table** in `using-orchestrator` —
  a rationalization table, which `writing-skills` and `CLAUDE.md` both ban,
  sitting in the skill that establishes those rules. Replaced by the precedence
  list, which addresses the failure that actually occurs: two skills matching at
  once with no stated order.
- **The `ORCH_WORKFLOWS` toggle** — documented in two places, read by no code, absent from `templates/settings.json` where the real knobs are declared. A documented switch that does nothing is worse than none: it gets set, and then trusted.

### Changed

- **Verification is checked by turn window, not by citation.** The gate asks the
  ledger whether a verify command ran green since this turn began. This is
  strictly stronger than a cited stamp: a model cannot opt out by declining to
  cite, and cannot reuse a stale green from an earlier turn. The three prompts
  that taught stamp citation now say the simpler true thing — run the command,
  paste the output.
- **The ledger records `substance`.** `exit 0` is not evidence: `swift test`
  exits 0 on "Test run with 0 tests in 0 suites passed". A green run that
  reported zero tests is now flagged. Silence is *not* flagged — `tsc` and
  `eslint` print nothing on success, and calling that "verified nothing" put a
  false note on every clean typecheck.
- **Absence of evidence is silent.** A project may verify with a command outside
  the regex; a gate that fires when it knows nothing is how agents learn to tune
  it out. Only a contradicted claim (hard) or a hollow green (soft) speaks.
- **`orch_grade_status_block` requires `Verify:` on DONE.** It required only
  `Summary:`, so a DONE with no verification passed deterministically and had to
  be caught by a 30-second LLM validator on every implementer return. That
  validator is now scoped to the one thing a grep cannot judge: whether an
  existing `Verify:` contains output or an assertion.
- **The per-turn reminder carries the precedence rule instead of restating
  SessionStart.** Every bullet in it was already in the eager block. The agent
  was reminded of the trigger ambiguity on 100% of turns and of its resolution
  on 0%.
- **Six skill descriptions** moved from `You MUST use this...` (unbounded: "ANY
  bug", "any feature", "before claiming any work") to `Use when X. Not for Y.`
  Those imperatives were what manufactured the trigger collisions. The linter no
  longer blesses the exception it banned in prose.
- **The empty-return warning is scoped to plugin agents** — it told the receiver
  to return a Status block, a contract only these agents have.
- `orch-explorer` is Opus: a scout's false negative silently narrows every
  decision downstream of it. `AGENTS.md` and `docs/anthropic-ecosystem.md` now
  agree with the frontmatter.

### Fixed — found by adversarial review, after the first round of fixes

Three adversarial passes ran against the changed tree; each found defects the
tests did not, including in code written that same day. Recorded because the
pattern matters more than any single bug: **every one came from a plausible
model of the shell that a shell does not share.**

- **Quote-blanking was unsound.** The first fix treated quoted text as data.
  `git -C "." reset --hard` blanked to `git -C   reset --hard`, whereupon the
  guard's own `-C` stripper ate `reset` and it ran — confirmed to wipe a tree.
  So did `git reset "--hard"`, `git "checkout" main`, and
  `echo "don't"; git reset --hard; echo "won't"` (the apostrophes PAIRED and
  blanked the command between them). Rewritten on `shlex` tokenization, which
  resolves quoting the way the shell does. 34 fail-opens closed.
- **`git` re-enters itself.** `git -c alias.pwn='!rm -rf .git' pwn` destroyed a
  repository while scanning as `git -c __ORCH_ARG__ pwn` — the option normalizer
  deleted the payload before any rule saw it. Same class: `submodule foreach`,
  `bisect run`, `rebase --exec`, `difftool --extcmd`, `filter-branch`. Also
  added `read-tree --reset` and `checkout-index -f`, hard-reset equivalents no
  rule covered.
- **A newline is a command separator; shlex thinks it is whitespace.** Two
  commands on two lines collapsed into one segment, so the `checkout -b`
  exemption from the first covered the real branch switch in the second — the
  hole the per-segment fix had just closed for `&&` and `;`, reopened for the
  way a model most naturally writes two commands.
- **`{a,b}` is one token to shlex and two words to bash.** `git {reset,--hard}`
  and `rm {-rf,.git}` executed while matching nothing.
- **A guard must never abort.** `set -e` plus one invalid-UTF-8 byte made BSD sed
  exit 1, which Claude Code reads as a non-blocking hook error — so the command
  ran. `set -e` removed from both guards; every failure path now falls through
  to the block logic.
- **The `.orch-worktree` marker was forgeable.** A hand-written `.git` file
  pointing at the main gitdir plus a touched marker relaxed the guard on a
  directory that resolved to the main repository, and a hard reset there dropped
  two commits on the shared checkout. The gitdir must now point inside
  `.git/worktrees/`.
- **The gate could say "your evidence is wrong" but never "you have no
  evidence".** A wholly invented `Verify:` block passed silently — warn AND
  strict — whenever the ledger was empty, and half of common runners
  (`./gradlew test`, `poetry run pytest`, `swift test`, `npx jest`) minted no
  row at all. Added the unbacked-claim check and widened the regex.
- **Printing is not running.** `pytest --version` and `pytest --collect-only`
  exit 0 having verified nothing and minted green rows that satisfied a claim of
  "40 passed". So did `npm ci` and `npm run build`. All excluded.
- **A heredoc body is not a command.** `cat <<EOF > CHANGELOG.md` whose body
  said "pytest -q now passes" minted a green row — and chained after a real red
  run, that laundered the failure. Writing a changelog that names the test
  command is ordinary post-fix behaviour.
- **Two false accusations that punished good work.** Pasting `make` output was
  blocked (make echoes its recipe, so `pytest -q` appeared at a command position
  and read as an unbacked claim), and so was honestly disclosing a suite that
  was *not* run — the model's cheapest fix would have been to delete the honest
  sentence. The rule is now: warn only when NOTHING the section names is backed.
- **A reply that documents the marker format** was accused of citing a
  fabricated stamp — which fired on any turn editing `orch-evidence.sh` itself.

### Added — closing the gap against the skill catalog this one descends from

A skill-by-skill content comparison against `superpowers@6.2.0` found real
technique missing here, most of it in the skills that matter most for
test-driven work. Ported in this catalog's register — the operational content,
not the coercive framing.

- **The red phase is now verifiable, which nothing else does.** "If you didn't
  watch the test fail, you don't know if it tests the right thing" is stated in
  every TDD guide and enforced by none, because checking it needs a record of
  what ran. The ledger already kept one; nothing read it as a *sequence*.
  `orch_evidence_red_first` asks whether the suite was ever seen failing before
  it was seen passing, and the gate says so when a turn changed a test file and
  the suite was only ever green. A test written after the code passes on its
  first run — so does a test that asserts nothing, never executes, or mirrors
  the implementation back at itself, and a green suite hides all four. Soft and
  scoped to turns that touched a test path: a docs turn has no red phase to skip.
- **`test-driven-development` rebuilt** (66 → 140 lines) around the verify-red
  step: fails rather than errors, the failure message is the one you predicted,
  and it fails because the behaviour is missing. Plus what a first-run pass
  means, minimal-green with a worked over-engineering counter-example, and a
  new `writing-good-tests.md` reference — name the break, derive expectations by
  hand (mirror assertions), no change detectors, mock at the right level, the
  mutation check.
- **`systematic-debugging`** (65 → 104): trace the bad *value* to its origin
  rather than reading the stack one level; instrument before the dangerous
  operation, with `console.error` in tests because a logger may be suppressed;
  compare against the closest working analogue and enumerate every difference;
  bisect test files to find a polluter; condition-based waiting instead of a
  sleep; architectural-failure signals reachable before strike three; and a
  legitimate no-root-cause exit.
- **`dispatching-subagents`** — the largest structural gap. The fix loop had one
  exit ("2 attempts") and no disposition for a finding it could not fix. Now:
  five rounds, resume for 1–3 and a fresh implementer one tier up for 4–5,
  re-review scoped to the fix diff with per-finding `ADDRESSED` / `NOT ADDRESSED`
  ("attempted" is not addressed), and adjudication at the cap into parked-with-
  ruling or `BLOCKED`. Every disposition is written down; a silently dropped
  finding is the failure this prevents. Plus one fix wave after the final review
  rather than one fixer per finding, durable per-task state with commit ranges
  so a controller after `/clear` knows where a mid-loop task resumes, no
  controller-side fixes, and no accumulated history in later dispatches.
- **Reviewer envelopes carry a read-only clause.** `dispatching-parallel-agents`
  already asserted the envelope must forbid the reviewer mutating the checkout;
  no envelope did. Also added: how far to look outside the diff (a named risk,
  one focused check), don't re-run what the implementer already ran, a
  `⚠️ Cannot verify from diff` channel distinct from low confidence, and the
  `plan-mandated` label for when the plan asks for something the rubric calls a
  defect.
- **`finishing-a-branch`** — the merged tree is now tested before cleanup. A
  branch green in isolation while base moved is the classic semantic conflict,
  and the regression check ran only as a precondition. Detached HEAD keeps the
  PR route (`git push origin HEAD:refs/heads/<new>`); dropping it stranded the
  work. Submodule guard added, here and in `using-git-worktrees`.
- **`verification-before-completion`** — a regression test is proved by reverting
  the fix and watching it fail, with that output pasted.
- Also: task right-sizing and a global-constraints block in `writing-plans`;
  scope-decomposition before questioning in `brainstorming`; understand-all-
  before-implementing-any and legitimate pushback grounds in
  `receiving-code-review`; match-the-form-to-the-failure and the no-guidance
  control in `writing-skills`; a subagent stop-block in `using-orchestrator`.

**Not ported, deliberately:** six rationalization tables, the Iron Law framing,
and the persuasion-principles reference. The strongest argument against them is
in the source catalog itself — its own skill-authoring guidance reports that a
prohibition produces *more* of the unwanted output than a positive recipe, and
worse than no guidance at all. That finding is ported; the style it argues
against is not.

### Added

- `scripts/lib/orch-json.sh` — `orch_json_field`, `orch_scan_source`,
  `orch_scan_is_tokenized`, `orch_shell_segments`. One place that decodes a hook
  payload correctly, and the only place that decides what a shell will do.
- `templates/researcher-prompt.md` — the researcher's dispatch envelope. Its
  contract requires eight fields and returns `BLOCKED` without them. All three
  dispatch sites are now fixed: `commands/research.md` pointed at the *output
  artifact* template and supplied two fields, and the two automatic triggers
  (`brainstorming` Trigger A, `writing-plans` Trigger B) named no envelope at
  all. The research gate was specified to fail.
- `tests/test-worktree-reaper.sh` (10 checks) and `tests/test-guard-no-verify.sh`
  (14 checks); regression cases added to the evidence-ledger, verify-gate,
  protocol-hooks, research-gate and destructive-git suites. Test isolation fixed
  throughout — suites shared fixed `/tmp` paths, so concurrent runs deleted each
  other's fixtures mid-suite and the research-gate suite failed intermittently.
- Verdict rules and a structured-output section on the three reviewer agents —
  they lived only in the template variants, and the native agent is the
  preferred dispatch path.
- `orch-code-reviewer` may write inside a fresh `mktemp -d`. The skeptic pass
  told it to execute a counterfactual while its own prompt said "never edit
  files", so the executed check silently degraded to a reasoned one.

## [0.6.0] - 2026-07-28

A platform-drift and failure-mode pass, targeted at the largest unaddressed clusters in the MAST multi-agent failure taxonomy (arXiv:2503.13657, N=1642: step repetition 15.7%, unaware-of-termination 12.4%, reasoning-action mismatch 13.2%, premature termination 6.2%), and at making verification something the model cannot narrate its way past.

**What is measured vs. not, plainly.** The behavioural evals (`tests/evals/`, n=3 per arm per case, model pinned, `results/benchmark.json` committed) measured: protocol-shape adherence is fully plugin-attributable (0/3 → 3/3), evidence formatting likewise (0/3 → 3/3), the research gate's negative control holds (3/3 silent), the per-turn reminder's **turn-one** contribution is zero (ablation: SessionStart injection alone scored 3/3), and on a micro bugfix the bare model fixes the bug as reliably as the plugin arm (held-out execution 3/3 both) at 14% lower cost. Everything else in this release — the termination contracts, the retry breaker's threshold, the evidence ledger's effect on fabrication rates, the speculative queue's wall-clock win on real suites, the fix-guided skeptic's FNR — is either covered by mechanical shell tests or **unmeasured and labelled as such** in README's "What is measured" section. Three prompt-level decisions were made on external evidence rather than local measurement, and say so: `effort:` frontmatter deliberately NOT adopted (per-agent pins were drafted during development and dropped before release — HAL's 21,730 rollouts found higher effort usually reduced accuracy, and Anthropic calls effort a session preference; agents inherit the session level), the TDD gate kept (arXiv:2605.26731: reasoning-tier models score best under strict harnesses — against arXiv:2603.17973's 30B-model result), and reviewer-tier ≥ implementer-tier kept (arXiv:2606.21811 Table 1).

### Added
- **Verification evidence ledger** (`scripts/hooks/orch-evidence-ledger.sh` on PostToolUse **and** PostToolUseFailure for Bash, + `scripts/lib/orch-evidence.sh`). Verify-shaped commands (test/lint/typecheck/build, command-position anchored) get a `[orch-evidence <stamp> exit=0]` line appended to their output via `hookSpecificOutput.updatedToolOutput`, and the same stamp recorded in a session ledger only the hook writes. The platform contract was pinned by live experiment against v2.1.220 (Bash `tool_response` exposes no exit code — the firing *event* carries the verdict; the output rewrite must be a Bash-schema object, not a string) and the stamp's arrival in the model's context was confirmed end-to-end in a live session. The Stop-hook verify gate and the SubagentStop validator check cited stamps against the ledger: fabricated stamps fail lookup; failing runs are ledgered but mint no citable stamp. Warn-only by default; `ORCH_STRICT_VERIFY=1` blocks. Honest boundary documented: this defeats fabrication, not an adversarial model with shell access.
- **Termination contracts.** Every plan task and dispatch envelope now carries `Done when:` (the only path to DONE) and `Stop if:` (fired → return `PARTIAL` or `BLOCKED`, never more attempts). New `PARTIAL` status (`Progress:` / `Remaining:`) added to the protocol, grader, templates, and docs. Enforced by a `type: "prompt"` SubagentStop hook that pushes an implementer back to an honest Status block when it trails off mid-work (platform caveat documented: prompt hooks cannot read `ORCH_HOOK_PROFILE`, so this single entry is active in every profile).
- **Speculative merge queue** (`scripts/orch-worktree-integrate.sh`, now the default; `--serial` keeps the old engine). All N branches batch onto an isolated integration worktree; the suite runs once at the combined tip; the base only ever fast-forwards to a suite-green SHA. Red tips first re-test the base state in the same worktree (environmental red → serial fallback instead of ejecting an innocent branch), then bisect out the first regressor and land the tested-green prefix. 48 mechanical checks in `tests/test-worktree-integrate.sh`.
- **Writer-mutex reaper** (`scripts/hooks/orch-worktree-reaper.sh`, SubagentStop on implementers). Releases a `.orch-active` mutex abandoned by a dead implementer — only on proof of ownership: the hook-recorded mutex map (by `agent_id`; sound because PostToolUse fires only on success, so a lost mkdir race records no claim), or a worktree named in a success-shaped final message (never a BLOCKED one, which routinely names a sibling's held tree). Unprovable leftovers are reported, never guessed at. This closes the worktree-poisoned-forever failure mode and is why the five read-only agents now carry `maxTurns` caps while the implementer still does not.
- **Protocol drift test** (`tests/test-protocol-drift.sh`) — pins the six shapes, the PARTIAL enum, and the per-turn reminder across every carrier surface; the reminder itself is now extracted at runtime from a marked block in `concise-agent-protocol.md` (single source; the hook's embedded fallback must be byte-identical or the test fails).
- **Eval harness upgrades** (`tests/evals/run-evals.sh`): `check` arrays grade the scratch project's real filesystem (held-out execution, not prose); `with_env` builds hook ablations; `--model` pins the eval model (inheriting an exhausted session model returns its limit notice as a $0 "result" and silently poisons every row); per-case output files make parallel single-case runs safe; the summary reports cost per solved task per arm.

### Changed
- **Retry-storm breaker is ON by default** (warn-only; `ORCH_RETRY_CAP=0` disables) and now fires on both events: Stop keeps the whole-reply fingerprint; SubagentStop scans the agent's own transcript for the same tool call with the same arguments ≥3 times consecutively — the step-repetition shape itself, keyed on `agent_id`.
- **Empty subagent returns are failures.** `subagent-stop.sh` previously exited 0 on an empty final message; it now warns (or blocks under `ORCH_STRICT_STATUS=1`) — premature termination must not read as success. The validator also reads `last_assistant_message` (the documented field; on SubagentStop `transcript_path` points at the *main* transcript) and scopes shape-grading by `agent_type`, so reviewers returning `Issues:` and native agents returning prose are no longer falsely warned.
- **Verify-gate WIP escape narrowed** to dirty tree AND a `wip` commit subject. A dirty tree alone is the normal mid-task state; escaping on it meant the gate almost never fired.
- **BLOCKED recovery branch 1 and NEEDS_CONTEXT resume instead of redo**: the controller sends the missing context to the same agent's `agentId` via `SendMessage` — partial work and context survive; a cold re-dispatch (which re-derives everything and is itself step-repetition-shaped) remains only where it is genuinely required: sibling output changed the ground truth, decomposition, or a model change (SendMessage has no model parameter).
- **Fix-guided skeptic pass** in `workflows/review-diff.js`: every finding must carry a `fix`; skeptics execute it in a scratch copy where the claim is runnable (original must misbehave AND fixed must behave — equivalence refutes), prose refutation remains the labelled fallback; survivors carry `verifiedBy: executed | reasoned`. This implements arXiv:2603.00539's measured countermeasure (FNR 54.8%→16.3% on HumanEval in the paper) instead of gesturing at it.
- **Agent models re-tiered upward — this raises per-dispatch cost.** `orch-implementer`, both reviewers, the security reviewer, the debugger, and the researcher move `sonnet` → `opus`; `orch-explorer` moves `haiku` → `sonnet`. Grounds: the reviewer-tier ≥ implementer-tier invariant (Claude Code's advisor rule; arXiv:2606.21811 Table 1 measures a weak critic at ±0–0.8pp vs a frontier critic at +17–22pp), Opus 5's May-2026 knowledge cutoff for the researcher, and the collapsed Opus↔Sonnet price ratio (1.7× today vs ~5× when the old tiering was chosen). At Sonnet's intro pricing an all-Sonnet roster is ~1.7× cheaper; if dispatch cost matters more than review strength, edit `model:` in `agents/*.md`. Per-agent `effort:` is deliberately not set — agents inherit the session preference (see above). `maxTurns` added to the five read-only agents (25–40).
- **Post-compaction protocol survival no longer depends on the per-turn hook**: `session-start.sh`'s compact path now injects the canonical reminder block alongside the recovery note.
- **Speculative-vs-serial and stricter-gate docs**: README, ARCHITECTURE, AGENTS, and `docs/anthropic-ecosystem.md` rewritten to describe the shipped behavior, including a "What is measured, and what is not" section in README.

### Fixed
- `install.sh --check` now lists every hook and lib the plugin actually ships (the verify gate, retry cap, signals, and detect libs were missing from the manifest check even before this release's additions).
- Evidence and state files are retention-pruned by the Stop hook (7 days).

## [0.5.0] - 2026-07-02

A delegation and honesty pass. Claude Code now ships native versions of several mechanisms this plugin built for itself (`/verify`, `/code-review`, `/security-review`, per-agent worktree isolation, auto-memory, plan mode); this release repositions the plugin as a thin policy layer over them — prefer the native mechanism when present, keep the rules the harness doesn't enforce. No new skills, commands, agents, or hooks; nothing removed.

### Changed
- **Delegation notes** in `verification-before-completion`, `requesting-code-review`, `using-git-worktrees`, and `managing-memory`: each names the native Claude Code equivalent, states when to prefer it, and pins down what remains this plugin's contract (the when-it's-mandatory gate, the spec-gates-quality order, the registry/baseline/merge-back discipline, the CLAUDE.md-vs-assistant-memory split). Every note keeps the standalone fallback for harnesses without the native feature.
- **Native equivalents map** — `docs/anthropic-ecosystem.md` gains a per-capability table (native feature | what the plugin adds | rule), dated 2026-07-02, replacing the vague "adopt upstream changes deliberately" advice with a concrete fold-in-and-delete rule. README gains a condensed version plus a research-grounding paragraph (GAIA scaffold comparison arXiv:2606.08529; MAST failure taxonomy arXiv:2503.13657; reviewer-overcorrection arXiv:2603.00539; Anthropic's Building Effective Agents).
- **Evidence-grounded review findings.** Critical findings now require concrete evidence, per the reviewer-overcorrection literature: the violated spec line (Stage 1), a failure scenario — specific inputs/state → wrong behavior (Stage 2), or a named exploitation path (Stage 3). Applied in the three reviewer agents, the `requesting-code-review` confidence rule, and `workflows/review-diff.js` (whose skeptic pass now treats a scenario-free critical claim as weak evidence by default).
- **Per-turn reminder trimmed ~40%** (measured: ~315 → ~190 tokens) — always-on per-exchange cost is a recurring criticism in independent Claude Code plugin reviews; the six shapes, the `Verify:` requirement, the `Found:`/`Plan:` routing, and the skill-trigger routing all survive the cut. (Measured per-turn injection floor after the trim: ~740 bytes ≈ 185 tokens; every other hook emits 0 bytes on its common path.)
- **Skill consolidation evaluated and rejected on evidence.** A swarm audit of all 18 triggers (with full reference inventories and adversarial verification) found no merge that would improve selection accuracy: the executing-plans/dispatching-* trio is condition-disjoint with self-correcting cross-links, the two code-review skills fire on opposite sides of the review event, and the handoff skill has its own validator contract and hook entry points. The one genuinely confusable pair — `using-workflows` vs `dispatching-parallel-agents` — is fixed by trigger differentiation and a cross-link, not a merge.
- **Exclusion clauses in trigger descriptions.** The five over-trigger-prone skills (`brainstorming`, `test-driven-development`, `systematic-debugging`, `requesting-code-review`, `using-workflows`) now end their descriptions with an explicit "Do not use when…" clause, matching Anthropic's skill-authoring guidance — positive triggers pull a skill in; exclusions push it out.
- **Spec and plan review are inline-first.** The fresh-subagent review after every spec and plan is now reserved for high-stakes cases (security-sensitive, irreversible, 5+ tasks); the default is an honest inline self-review checklist. Independent-context review stays mandatory where independence pays: code diffs. (Practice evidence: superpowers measured inline self-review catching the same real gaps in seconds instead of ~25-minute subagent round-trips.)
- **Declared task interfaces.** Plan tasks may declare an `Interfaces:` block (`introduces:` / `consumes:`); `executing-plans` treats it as the authoritative dependency signal and body-scans only tasks without it — replacing pure inference with declaration, per the multi-agent failure literature's top failure cluster (under-specification).
- **README slimmed for credibility.** The 18-row feature table is cut to 9 outcome-level rows (substrate detail moved to ARCHITECTURE), the dynamic-workflows footnote is gone, unverifiable effectiveness claims ("most blockers resolve…") are rephrased as design intent, and the Building Effective Agents link uses the canonical `/engineering/` URL.
- **Research-gate uncertainty notice now reaches the model.** `RESEARCH_UNCERTAIN` was written to stderr with exit 0, which Claude Code never injects into context — a silent no-op. It now emits as `additionalContext` on the rare uncertain path (~150 bytes, only when it fires).

### Fixed
- `marketplace.json` version had drifted two releases behind (`0.2.0` while the plugin was `0.4.0`); both now read `0.5.0`, and its description says 18 skills (was 17 — stale since `using-workflows` shipped in 0.3.0). Same 17→18 fix in ARCHITECTURE.
- ARCHITECTURE's layer diagram still described the SessionStart injection as "wrapped in EXTREMELY_IMPORTANT directive framing" — that framing was removed in 0.4.0; the diagram now says what actually ships (plain-voice ~545-token core).
- ARCHITECTURE's data-flow example said handoff triggers at "~50%" of context — a leftover from a pre-0.2.0 design; the real trigger is `ORCH_CONTEXT_HANDOFF_TOKENS` (default 950000, ≈95%).
- The ecosystem doc's subagent roster and model table omitted `orch-researcher` and `orch-security-reviewer` (listed 6 of 8 agents).
- `docs/manual-testing.md` expected outputs were stale: "OK: 17 skills" (now 18) and "All 61 checks passed." (now 65).

## [0.4.0] - 2026-06-01

A reliability, cost, and tone pass. The orchestration behaves the same; it now costs far less context per session, says things plainly instead of shouting, ships new opt-in safety nets (all off by default), and is guarded by a wider test net. No breaking changes — every new enforcement is opt-in behind an `ORCH_STRICT_*` flag, and the safety guards explicitly resist the new dry-run switch.

### Changed
- **Far less context burned per session.** The SessionStart injection now sends only a marked protocol core (~545 tokens) instead of the whole meta-skill (~2,100 tokens); the full routing table, red-flag list, and dispatch detail stay in the skill file and load only when the agent reads them. The per-turn reminder was trimmed ~41% (~534 → ~314 tokens). A one-shot session now adds ~900 tokens of orchestrator framing, down from ~2,675. A custom meta-skill without the `<!-- ORCH:EAGER -->` markers falls back to full-body injection, so nothing breaks.
- **Plain voice, no coercion.** Removed the `<EXTREMELY-IMPORTANT>` / "1% chance" / "you have no choice" framing from the meta-skill, the per-turn reminder, and the SessionStart preamble, aligning with Anthropic's own published skills. The rules are unchanged; only the tone is. The skill validator's shouting check is now strict everywhere (no directive-block carve-out).
- **Leaner research-gate payload.** The gate's injected guidance dropped from ~1KB to ~330 bytes (prior-findings markers kept); a version question about the orchestrator plugin itself ("what version of llm-orchestrator is installed") no longer fires the gate, while real library/version lookups still do.
- **`research-classifier` split for readability.** The 2,700-word skill is now a ~1,000-word core plus `STRATEGY.md` (aggressiveness, stakes, MCP-nudge rules) and `EXAMPLES.md` (the curated cases the smoke test checks). Skill descriptions across the catalog were tightened toward trigger form. Subagent codenames were removed from user-facing prose (operational dispatch instructions keep them).

### Added
- **Retry-storm circuit breaker** (`scripts/hooks/orch-retry-cap.sh`, Stop) — when the controller repeats essentially the same reply `ORCH_RETRY_CAP_N` times (default 3), it nudges the user to stop and reassess. Off by default; `ORCH_RETRY_CAP=1` to warn, `ORCH_STRICT_RETRY=1` to block. A different reply resets the counter, so normal progress never trips it.
- **Verification gate** (`scripts/hooks/orch-verify-gate.sh`, Stop) — warns when a `Changed:` block ships without a `Verify:` line. Warn-only by default; `ORCH_STRICT_VERIFY=1` to block. Escapes on a dirty tree or a `wip` commit so work-in-progress isn't nagged.
- **Opt-in usage telemetry** (`scripts/hooks/skill-telemetry.sh`, PostToolUse) — when `ORCH_TELEMETRY=1` (env or project `.orchrc`), appends one line per skill invocation: skill name + timestamp + project hash, and nothing else. Never logs prompts, arguments, or output. Off by default.
- **`ORCH_HOOK_DRY_RUN=1`** — every injecting/grading hook logs what it *would* inject or block, then does nothing. The two git safety guards deliberately ignore it (they can never be made bypassable).
- **`ORCH_DISABLE_PROTOCOL_GRADER=1`** — full opt-out for the protocol grader; `ORCH_STRICT_PROTOCOL=1` always wins.
- **Composite `verify=` key** in `orch-detect.sh` — a single runnable check (documented verify script, else composed test/lint/typecheck) so a verification gate has one command to point at.
- **New tests:** hook latency budget (every per-turn hook < 500ms; SessionStart budgeted separately), opt-in telemetry, the verification gate, and the retry breaker. Plus verify-key detection cases and a SessionStart eager-body budget guard.
- README gains a **Hook precedence** section: defaults permissive, enforcement opt-in (`ORCH_STRICT_*`), capture opt-in (`ORCH_TELEMETRY`).

### Hardened
- **SessionStart latency:** a ~570ms per-session stall (a bash end-of-script buffer artifact, surfaced by the new latency test) is gone; the eager-body trim keeps it lean.
- **`validate-skills.sh`** now actually catches a command that references a non-existent skill (the old reference check was tautological and could never fail), and discovers skills dynamically so a rename needs no test edit.
- **`orch-lock.sh`** cleans its tempfile on interrupt via a subshell-scoped trap that never clobbers the caller's own signal traps.
- **python3 dependency** for the protocol/Status graders now surfaces once, loudly, at session start when it's missing, instead of only at grade time.
- The privacy posture in ARCHITECTURE and the ecosystem doc was amended in step with the new telemetry: tool outputs, arguments, prompts, and transcripts are still never captured — the one opt-in exception is event-only skill telemetry.

## [0.3.0] - 2026-05-31

### Added
- **Code review now runs on Claude Code's dynamic workflows, when that tool is available.** The two reviews (does the code match the spec, then is the code any good) plus the conditional security pass can now execute as a single deterministic script that runs the reviewers in parallel, returns their findings in a structured form, and has independent agents try to disprove each finding before it ever reaches you. Previously the controller coordinated these stages by hand. If the tool isn't present (any non-Claude-Code harness), the original step-by-step markdown flow runs instead — unchanged — so nothing breaks.
  - New `workflows/review-diff.js` — the review pipeline. The spec-compliance review still gates the code-quality review: a diff that doesn't implement the spec exits early instead of paying for the rest. Findings the reviewer is less than 80% sure about are dropped, and a bounded "try to refute this" pass (at most four agents, so a noisy diff can't run up the bill) double-checks what's left before it surfaces.
  - New skill `using-workflows` — the plain-language rule for *when* a workflow is worth it (work that splits into independent parts and is valuable enough to justify the extra agents) versus when to stay in one agent (step-by-step work that shares context — most coding). Grounded in Anthropic's published guidance that multi-agent runs cost roughly 15× the tokens of a single agent, so the fan-out has to earn it.
  - New validator `tests/validate-workflows.sh` — checks every workflow script for syntax and for the constructs the engine forbids that a plain syntax check silently lets through.
  - Reuses the existing `orch-spec-reviewer` / `orch-code-reviewer` / `orch-security-reviewer` agents directly (through the workflow tool's `agentType` option) — no new agent roles.
  - The list of security-sensitive keywords stays defined in exactly one place (`scripts/lib/orch-signals.sh`); the workflow is handed a simple yes/no flag instead of re-implementing the rule, so the two paths can never drift on what counts as security-sensitive.
  - Research brief backing the design (the Workflow tool's contract + Anthropic's cost guidance): `docs/llm-orchestrator/research/2026-05-31-workflow-tool-contract.md`.

### Changed
- ARCHITECTURE gains a **Workflows** component section and admits `workflows/*.js` as a deliberate, Claude-Code-only accelerator for the review layer (and, next, parallel dispatch) — with the plain-markdown path kept as the canonical, runs-anywhere default. AGENTS notes the agent reuse; README adds two feature rows.
- The two-stage review is now a *preferred* substrate, not a hard dependency. The markdown path is the canonical fallback; the workflow path is explicitly higher-rigor, not claimed to be behaviorally identical.

## [0.2.0] - 2026-05-30

### Added
- **Context-aware handoff (Layer 9)** — keeps a long task on track across Claude Code's automatic compaction (when it summarizes older conversation to free space). When token usage first crosses `ORCH_CONTEXT_HANDOFF_TOKENS` (default 800000), the agent is reminded once — not every turn — to write a short handoff note at `docs/llm-orchestrator/handoffs/<date>-<slug>.md`: a few bullets covering what's done, what's next, and the verify command with its result. After compaction, a short reminder tells the next turn to re-read that note, trust the plan file's checkboxes, and re-run the tests before continuing.
  - New hook `scripts/hooks/orch-handoff-nudge.sh` (`UserPromptSubmit`) — the one-time write reminder. Fires once per fill cycle, re-arms after a compaction, and never blocks.
  - `session-start.sh` injects the post-compaction reminder.
  - New skill `handing-off-to-fresh-context` and command `/llm-orchestrator:handoff` — write the note; a clean stopping point (tests green, nothing in flight) is the preferred moment. `executing-plans` writes one at tier boundaries.
  - New lib `scripts/lib/orch-handoff.sh` — context-fill estimation from the transcript.
  - One setting: `ORCH_CONTEXT_HANDOFF_TOKENS` (default 800000) — lower it for a smaller context window.
  - Docs: ARCHITECTURE Layer 9, README feature row, AGENTS command entry, settings.json documentation.

### Added (discoverability)
- New command `/llm-orchestrator:skills` — prints a one-screen catalog of the available skills and commands with their trigger conditions, grouped by phase, with an optional keyword filter. Renders from the session's injected catalog (no filesystem dependency, so it works from any working directory).

### Hardened
- Reliability: the transcript read is bounded to a tail slice for constant per-turn cost on long runs, and the context-window size is validated against non-numeric/empty values.
- Cross-shell + install-layout robustness for commands/skills that source plugin libraries: a shared resolver locates a lib across all install layouts (`$CLAUDE_PLUGIN_ROOT`, the symlink/copy installs, and the version-nested marketplace cache — version-sorted so a stale older copy is never picked), and the libraries self-locate with `${BASH_SOURCE[0]:-$0}` so sibling `source`s work when a lib is loaded under zsh (where `BASH_SOURCE` is unset). Previously a command run from a user's project under a zsh-default shell could fail to find or correctly load a lib. New regression test `tests/test-lib-resolution.sh`.

### Changed
- ARCHITECTURE renamed "Eight layers" → "Nine layers".

## [0.1.0] - 2026-05-23

<!-- Note: date is approximate; no earlier release tag found in git log. -->

### Added
- Initial release: Concise Agent Protocol, skills + commands, two-stage review, research gate, project memory, evidence-based verification, parallel/sequential dispatch, git-worktree isolation.
