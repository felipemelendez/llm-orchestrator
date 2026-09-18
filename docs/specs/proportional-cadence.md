# Proportional cadence and automatic task cleanup

Status: approved specification, independently reviewed by Codex and Claude with review corrections incorporated.
Owner: Felipe Melendez. Requested 2026-09-16.
Framework baseline: `e4963987fca1d0f3f9719215b91141d0ae8cab74`.
FTApp baseline: `58b329bd14e774b7986217b5e976cc4b4a957933`.
Authoritative home: the framework's `docs/specs/proportional-cadence.md`; scratch copies and all review reports are temporary.

## Problem and outcome

Removing one informational navigation toast triggered multiple agents, eight report files, duplicate test execution, disposable repositories, mutation probes and a TypeScript positive control. The current cadence applies its largest workflow to every production change. Its Git gate requires five named reports, and its cleanup hooks primarily prune caches or release mutexes rather than remove completed task resources.

The replacement must preserve useful verification while making process proportional to the work. A simple change is implemented, checked and delivered directly. More involved changes receive an independent reviewer. Complex or consequential work receives the fuller review process. Task-created temporary artifacts are cleaned automatically without losing unfinished work. The same policy must apply in Claude and Codex, in the shared framework and in FTApp's installed project rules.

This framework change itself receives a reviewed specification, implementation, independent Claude and Codex reviews, resolution of findings, and relevant non-build verification. Missing Claude authentication is a prerequisite to resolve, never permission to relabel a second Codex review as Claude.

## 1. Workflow selection

Add an explicit project setting `"workflow": "proportional"`. New initialization defaults to proportional. Absent `workflow`, or explicit `"legacy"`, preserves the existing project's legacy report-based behavior until a deliberate migration. Unknown values are an actionable configuration error, not permission to skip checks. Disabled or absent cadence remains inert.

For proportional projects, the controller selects the smallest sufficient path using user impact, uncertainty, affected boundaries and reversibility. File count and line count are supporting context, never automatic thresholds. Selection is a short explanation in the conversation when useful; simple work does not require a ticket, classifier file or separate briefing agent. Reassess if investigation or implementation expands the risk or scope. Current user instructions and explicit requests for particular reviewers take precedence.

| Path | Selection | Required work |
| --- | --- | --- |
| Simple | Clear local intent, readily reversible, low user impact, no meaningful uncertainty or cross-system contract change | Implement in the current checkout when safe, inspect the complete diff, run relevant existing checks, state the outcome. No mandatory subagents, worktree, specification, report or new test. |
| Standard | A bounded behavior change, meaningful edge cases, or a small sensitive change that benefits from another judgment | State acceptance criteria, implement, run focused checks, obtain one independent review, resolve actionable findings and verify affected fixes. No mandatory brief reviewer, blind pair, refuter, mutation gate or stage reports. |
| Full | Broad interacting changes, architecture or data lifecycle changes, difficult recovery, substantial uncertainty, or consequential verification/security/safety contracts | Review the specification/brief, implement, obtain two independent reviews, adjudicate, fix and independently verify. Use a refuter only for substantive disagreement or a serious/catastrophic finding raised by one reviewer alone. Apply the deterministic gate and additional probes to the affected contracts; unsupported or skipped validation remains explicit. |

Examples: routine-toast removal is Simple; a bounded retry-state correction is Standard; a multi-service migration or redesign of verification/cleanup controls is Full. A large mechanical rename need not be Full. A one-line permission check is not automatically Simple. Failed checks require diagnosis; they do not automatically create another agent pipeline.

The writer may inspect their own diff and execute tests in every path. Those actions are not an independent review. Where an independent reviewer or gate is required, the writer cannot fill that role. The controller does not invent an additional reviewer merely to repeat an already completed independent review.

## 2. Verification and completion

Extend the existing execution-evidence systems in both harnesses to meet the same completion contract. Successful commands need observed exits, appropriate scope and fresh final-source binding. Unavailable, interrupted, empty or failed checks are not passing evidence. Provider receipts are not test results. Do not loosen checker configuration to manufacture success.

Verification belongs to the unfinished task and its affected source, not just its latest assistant turn. A question, pause, documentation edit, turn boundary or content-preserving commit must not clear an outstanding source-verification obligation or an unresolved failed check. Conversely, a successful applicable check remains reusable across turns and content-preserving commits while its checked source, test/configuration inputs and command contract remain unchanged. Record HEAD for provenance, but do not use a changed commit identifier alone to invalidate identical content. Another check cannot clear a failure outside its coverage. Missing evidence remains pending; it must never be reconstructed from a written success claim.

Record the canonical project/worktree, observed command identity and exit, actual checked scope and content fingerprint with the existing private evidence. Reuse requires the same applicable source and check inputs, not a controller's assertion that a change was unrelated. Relevant subsequent source/test/configuration changes invalidate the affected evidence. Keep unrelated failures and unfinished source edits visible until resolved or accurately reported pending/blocked. Do not clear them just because a later turn makes no verification claim.

Use these deterministic rules for attribution and scope:

- An observed write to a resolved project source/test/executable-configuration path creates an obligation. Resolve structured tool paths and supported shell write operands against their actual working directory; a whole-tree difference alone does not attribute a write to this task. A resolved documentation or owned external-scratch write creates no source obligation. For an unresolved potentially mutating target, record uncertainty and require a PENDING/BLOCKED disposition unless subsequent trustworthy tool evidence resolves it; never label it read-only or manufacture a successful check to clear the uncertainty. Unknown cwd or missing events are likewise explicit uncertainty.
- Select a check's scope from normalized observed command path arguments matched to optional project-configured `verification_scopes`. Each named definition supplies selector globs and complete input globs covering the selected tests, their production dependencies and required configuration; a test-file argument alone is never the entire dependency scope. Union all matched scopes. If any path argument is unmatched, the command has no resolvable paths, or a selected definition cannot be validated, use the configured project-wide production/test/configuration inputs conservatively (invalid configuration is still reported). Do not guess an import graph or accept a prompt-supplied list of supposedly irrelevant changes.
- The fallback inputs are `prod_globs`, `test_globs` and a new explicit `verification_config_globs` configuration key, together with the shared runner/configuration/lock inputs below. Missing or invalid definitions, or an empty resolved production/test input set, are not a valid conservative scope: retain an unresolvable-scope record, disallow passing/reusable evidence, leave the obligation PENDING, and identify the configuration needed. Never use the constant fingerprint of an empty set as proof of unchanged source. This includes the existing unknown runner profile with empty globs.
- Fingerprint the selected inputs, the scope definition, applicable shared runner/configuration/dependency-lock inputs and command identity. Include additions and deletions matching the scope globs. HEAD, turn identifiers, reports and ordinary prose are provenance or excluded artifacts, not source inputs. Changes outside the recorded scope do not invalidate that check. Changes inside it do. A check clears only obligations it covers; conservative fallback may require more revalidation and must not be advertised as perfect dependency inference.
- The FTApp migration defines useful existing check scopes, including the app Jest inputs separately from backend/native inputs, while including any actual cross-boundary dependencies. Tests use explicit scope fixtures to prove that an unrelated native edit preserves an app check and that a covered production/test/configuration edit invalidates it.

Persist the observed command identity and exit before expensive scope/fingerprint processing. Failure, timeout or disappearance during fingerprinting leaves an explicit unknown-fingerprint record, unusable for a passing/reusable verdict; it must never drop a failed command's record. A pre-execution pending marker survives interruption before an exit can be observed. Scope/receipt processing errors remain visible to completion checks. Test slow/failed fingerprinting, disappearing files, missing HEAD and interrupted hooks without inferring a passing result from missing rows.

This requires changes to Claude's evidence path as well as Codex's: Claude's current turn-only, source-unbound ledger cannot supply this contract unchanged. Extend the existing ledger/gate to retain and validate observed evidence across turns and bind it to source content. Keep each harness's existing private store; neither add another parallel database nor merge the two stores into a new service. Test both adapters with real observed command outcomes, including stale evidence, missing events and interrupted checks. Scope these changed lifecycle semantics to proportional projects; legacy projects keep their existing contract unless explicitly migrated.

An observed delegated check may be reused only when trustworthy execution provenance identifies the parent task, delegated command, canonical working directory, actual result and matching checked contents delivered to the parent. A child report or provider receipt alone does not qualify. Never import an unrelated session's/worktree's checks based only on similar paths or hashes. Where a harness cannot expose sufficient delegated execution provenance, state that limitation and perform the necessary observed check; do not promise universal cross-agent reuse or routinely rerun a check whose trustworthy evidence is already supported.

All three paths use the harness's supported execution route on their first check invocation. In evidence-enabled Codex projects, invoke the installed `scripts/verification/codex-verify.py` runner with fresh private output/receipt paths; ordinary direct commands do not become trusted results from their printed output. Claude uses the updated observed-execution ledger/gate. Teach these routes in the short path instructions so agents do not first run an unbound check and then repeat it through the proper route. Remove stale hook guidance that unconditionally demands rerunning a delegated check when supported trustworthy evidence already exists.

Both proportional harnesses accept the same `Verification:` completion vocabulary: `PASS — <observed checks and scope>`, `PENDING — <remaining required validation>`, `BLOCKED — <specific unavailable prerequisite>`, and `NOT APPLICABLE — <why no automated check applies; manual diff inspection performed>`. PASS requires valid observed evidence; text alone never supplies it. NOT APPLICABLE is an explicit applicability judgment for low-risk work without a meaningful applicable automated check, recorded as such rather than as an executed pass. It cannot waive a recorded failure, unknown mutation target, required stale check, or unavailable required build/device/service validation; those remain PENDING/BLOCKED. Gates must not force invented tests or reject the shared completion format because Claude formerly expected `Verify:`. Existing projects in legacy mode retain their existing forms. This vocabulary is the proposed future contract, not authorization to bypass today's gates.

Choose checks for the affected subsystem. Reuse existing relevant tests. Add a regression test when it protects meaningful behavior; do not add a test merely to mirror a reversible deletion or assert that a removed string is absent. Run each relevant successful check once for the final source; rerun only for relevant changes, failures or unresolved concerns. Do not run app-wide checks, full mutation batteries, or checker positive controls by default for Simple/Standard work. Positive controls are appropriate when changing verification infrastructure or investigating whether a checker actually runs.

Questions, specification discussion, ordinary documentation and deletion of transient reports do not acquire a source-testing obligation solely because another session changed or committed code. Attribute writes from observed tool targets and source changes, not from an agent's description of its intentions. Preserve source verification obligations for code this task actually edits, including edits before an intervening discussion turn. A concurrent change affecting that source can invalidate its evidence. Ambiguous or missing mutation observations cannot establish that an actual source-writing task was read-only. Include regression scenes for discussion/cleanup after an unrelated commit, an unverified source edit followed by discussion, and an already verified change followed by a content-preserving commit.

For this change, use non-build checks and existing dependencies. FTApp's prohibition remains: Felipe owns builds, native installation, `ios/Podfile`, and `ios/FindTribe/Info.plist`. Preserve each other project's authorized verification commands; do not turn FTApp's preference into a global prohibition on explicitly authorized builds elsewhere.

Describe enforcement conditionally: evidence hooks enforce only when installed, enabled, loaded and trusted in the relevant harness. Missing/disabled hooks or untrusted changed definitions do not prove execution or review. Report their activation state accurately. New proportional initialization must deliberately configure its intended execution-evidence policy, or explicitly report execution enforcement inactive; proportional workflow selection alone is not activation. Instructions still require honest verification, and the Git lock does not attest that tests ran.

### Hook cost and long-session acceptance

Source binding protects against reusing a check after its actual inputs change;
it is not a reason to rescan a repository on every conversation turn. The
September 17 timeout exposed missing workload coverage: 25 distinct retained
checks repeatedly fingerprinted approximately 4,780 FTApp files at completion,
including 23 results already known to be unbound. A read-only replay exceeded
25 seconds against a 10-second hook limit.

- Ordinary discussion, read-only replies and truthful pending/blocked handoffs
  must not hash repository contents. Preserve outstanding obligations and return
  their honest disposition without asserting fresh passing evidence or clearing
  them. A deliberate passing claim still requires current source binding.
- Results already known to be failed, interrupted, empty, unbound, missing a
  start, or missing a usable fingerprint remain unresolved without a new source
  scan. In Codex, a direct invocation that cannot supply a trusted execution
  receipt must not pay for fingerprints at either command boundary.
- When fresh binding is necessary, enumerate candidate inputs once and reuse
  content reads across overlapping scopes within that invocation. Preserve each
  command's scope, configuration and identity in its own fingerprint. Reuse must
  not cross execution boundaries or subsequent hook invocations based only on
  file timestamps, HEAD, a prompt, or an assertion that nothing changed.
- Additions, deletions, configuration and dependency changes must still stale
  affected checks. Unknown or interrupted observations stay unverified. Do not
  drop failures, broaden a passing check's coverage, reset session history, or
  disable evidence to make the hook fast.
- A yielded verification process retains its exact invocation binding until
  its terminal receipt can be consumed once, including after `write_stdin`.
  Interrupted or ambiguous execution stays pending; recovery cannot replace a
  failure with an unrelated result. Known write targets likewise remain pending
  while their process runs, including writes occurring after the first response.
- Identical repeated start/completion observations are idempotent: retain the
  first source baseline and execution binding, and do not create a missing-start
  obligation after already consuming that exact completion. Conflicting reuse
  of an invocation identity remains explicitly unverified. Cover source edits
  and actual check processes in both harnesses, including out-of-order results.
- Shell attribution covers supported sed output-writing forms as well as
  in-place edits; unsupported potentially writing programs remain uncertain.
  A no-scan reply cannot promote a pending, stale or failed disposition to
  verified. Only current explicit validation can establish that outcome.
- Routine Stop cleanup and pruning skip busy tasks without waiting on unrelated
  project locks or attempting unbounded deletion. Explicit task finish remains
  responsible for complete safe cleanup; a hook may defer work without losing
  its recovery state or weakening ownership and consumer checks.
- Bounded evidence-lock contention preserves compact, invocation-scoped
  observations for exact-once consumption with their original identity, order
  and observation time. Read-only/control observations do not invent a source
  gap or deny a harmless tool. Persist normalized facts/hashes rather than raw
  commands, output or prompts. A missed source/check baseline remains unresolved;
  later processing cannot manufacture a baseline from before execution. Do not
  replace lost observations with an irrecoverable session-wide sentinel or merge
  snapshots against changed state without checking that state's revision.
  Preserve normalized pending validation declarations across contention, including
  build/device requirements and distinct turn identities. A deferred terminal
  event with an original known-target baseline may create conservative path
  obligations without hashing source; only checks started after that terminal
  observation can cover them. Missing baselines and uncertain completion remain
  unverified. Running/background metadata takes precedence over positive output,
  and a late failure requires a matching check started after that failure.
- The trusted runner publishes a bound terminal setup-failure receipt when an
  error occurs before its child starts and the receipt destination is usable.
  Such a receipt earns no passing credit, closes only its own invocation, and
  allows a later matching successful check to supersede that failed attempt.
  Missing/reserved receipts, raw stdout and interruption flags alone are not
  terminal proof; retain actual running/finishing processes and their binding.
- Recognize common read-only sed address/range forms structurally while keeping
  write/execute commands and flags, script files and unsupported forms guarded.
  Judge shell syntax by quoting: a `$`, backtick or brace inside single quotes
  (or escaped) is literal program text and stays read-only, while the unquoted
  or double-quoted expanding forms, redirections and subshells stay uncertain.
  An unquoted newline separates commands like `;`; a multi-line batch of reads
  is read-only only when every line is.
  A resolved external operand is outside the current repository's coverage;
  cleanup ownership does not determine verification attribution. Preserve all
  inside-tree operands of mixed operations and canonicalize symlinks first.
  This neither verifies another tree nor excuses unknown scripts/targets.
- Content-bound successful checks remain reusable after a PENDING handoff for
  independent review. Preserve actual failed/unbound attempts, matching-command
  service recovery and explicit build/device requirements; the handoff timestamp
  alone does not require another identical successful invocation. Shared lockfile
  inputs must identify dependency locks without matching unrelated source names
  such as `BlockedUsers.tsx`. Diagnostics distinguish unclaimed observed success
  from a check actually found stale.
- Performance checks cover both adapters, thousands of representative files,
  dozens of old/unbound and overlapping valid checks, ordinary later turns,
  and contention/interruption. Assert bounded scan/read work deterministically;
  also measure a read-only replay of this real FTApp session and actual installed
  hook entrypoints against isolated state. Completion must finish comfortably
  inside the existing 10-second limit; increasing that limit is not the fix.

The updated contract and final source require independent adversarial Codex and
Claude Fable review, resolution of material findings, and non-build verification.
Record the actual served Claude model; another model cannot satisfy the Fable
request silently. Keep probes and reviews in disposable owned scratch.

Codex's raw shell output cannot distinguish a completed write from a yielded
process that may write later. Keep that case explicitly unverified unless a
trusted terminal/cancellation observation is available; a later passing check
does not prove the writer stopped. Use native patch/edit tools for ordinary
source changes and the trusted runner for checks. Do not claim universal shell
completion support or settle an interrupted writer from its output alone.

## 3. Git policy and compatibility

Separate protection of project rules from storage of task reports.

For proportional projects, matching a ticket-shaped commit message or running `--landing` must not require BRIEFREV/REV1/REV2/REFUTE/GATE Markdown files, a ledger row, or a notes directory. Git's lock and numbered-ruling checks continue to apply. Executed verification remains enforced by the harness's evidence hooks and applicable CI; reviewer number, independence and semantic workflow choice are instructions, not falsely claimed mechanical attestation.

The checker must state this boundary honestly. A clean Git policy check is not proof that tests or reviewers ran. Historical revision audits use that revision's configuration: legacy commits retain legacy behavior; proportional commits do not become unauditable when temporary reports are deleted. Invalid configuration does not silently select a lighter path. Test staged-versus-HEAD policy transitions and preserve the existing protection against disabling the cadence by an unstaged config edit.

For `--commit-msg`, enforce cadence when either the staged configuration or HEAD enables it. An enabled staged configuration determines `workflow`; otherwise an enabled HEAD configuration determines it. If neither enables cadence, it is inactive. The working-tree configuration never selects commit policy. Validate the relevant blobs and perform protected-file/ruling/lock checks before allowing their selected workflow to waive report requirements. Consequently, a valid staged legacy-to-proportional ruling uses proportional report policy for that migration commit itself; a staged switch back to legacy uses legacy policy. An unstaged flip has no effect. Unauthorized flips and malformed relevant configuration fail explicitly. `--audit` selects policy from the audited revision's configuration; direct `--landing` uses the current project configuration without asserting commit authorization. Cover all transitions, including staged disablement with enabled HEAD.

Do not retrofit a complex second evidence database merely to replace the five reports. Use the existing harness receipts, plus the conversation or PR summary for review disposition. Keep the full legacy mode available for projects that explicitly require its artifacts.

## 4. Document retention

Persist documents because they help future work: maintained specifications, useful research conclusions, architecture/contract decisions and operational instructions. Prefer updating an existing authoritative document. Research dumps and speculative notes do not become permanent merely by being called research.

Review transcripts, per-stage status reports, mutation logs, temporary plans, disposable snapshots and consumed handoffs belong in task-owned temporary storage outside the repository. There is no default requirement to commit them in any proportional path. Promote a lasting discovery into maintained documentation and remove the raw report.

Use existing private receipt storage for machine evidence. Evidence referenced by pending verification/review must remain available until consumed. Completed private execution evidence may have bounded retention for diagnostics, but must be automatically pruned; do not delete files while completion verification still reads them. This retention is distinct from disposable workspace cleanup.

No bulk deletion of existing research, previous sessions' documents, worktrees or branches. Migration changes future behavior; existing resources require ownership and preservation checks before deletion.

## 5. Task resource lifecycle and safe cleanup

Provide one small shared resource helper usable by both harnesses and installed layouts. It allocates a unique private task scratch root outside the repository only when a task needs temporary artifacts or isolated worktrees. Simple work that creates none does not need a manifest. The helper records the project, task identity and the resources it creates; arbitrary pre-existing paths cannot be retroactively claimed by filename or age. Cleanup requires no exemption from existing destructive-Git guards.

The controller completes cleanup as part of delivering a finished task, without asking the user to approve ordinary deletion of that task's disposable artifacts. Use an explicit finish operation after all consumers have stopped and deliverables are preserved. An assistant Stop event ends a turn, not necessarily the task. A shared cleanup hook may retry cleanup of explicitly finished tasks; it must never infer completion from a Stop/SubagentStop event or a successful-looking message.

Resource creation/registration, consumer acquisition/release and finish share one exclusive per-task lifecycle lock stored outside the deletable root. Consumers register before accessing managed resources. Finish atomically closes admission to new resources and consumers, then rechecks existing consumers, ownership and preservation before deleting. If a consumer already holds a lease, finish retains the resources and reports that dependency; if finish wins, later acquisition fails before the consumer can use them. A failed or partial cleanup retains an explicit closed/pending state and recovery pointer; retry cannot silently reopen admission. Concurrent finish/retry calls are idempotent under the same lock. No check-then-delete gap may allow a managed reviewer or verifier to start between the activity check and deletion. Arbitrary external filesystem writers are outside the helper's coordination; observable replacement/state changes or uncertain ownership require preservation, not a claim of universal race protection.

A worktree mutex and a task consumer lease are separate claims. Reaping a mutex does not release a consumer lease. A trusted lifecycle event may release only the matching consumer generation when it proves that consumer and its tracked children/processes have stopped; otherwise retain the lease for explicit verified recovery. A parent Stop or an unrelated SubagentStop cannot release it. Releasing the final lease still does not mark an unfinished task complete or authorize deletion on its own.

Cleanup requirements:

- Remove only paths created/registered for that exact task under its managed scratch root. Resolve ownership and canonical path boundaries; reject symlink roots, traversal, malformed manifests, unrelated repositories and replacement paths that no longer match the owned resource.
- Preserve resources used by active writers, reviewers or verifiers. A mutex, registered active consumer, Git worktree lock or uncertain ownership prevents deletion. Age alone does not prove inactivity.
- Use normal `git worktree remove` for owned linked worktrees; never `--force`. Check tracked changes, staged changes, untracked content and ignored files that could contain unique work before calling Git: non-forcing removal alone does not protect ignored content. Do not remove a primary checkout or submodule.
- A clean worktree may be removed only when its commits remain reachable from a retained named ref or an explicitly verified preserved destination that survives the entire cleanup set. A detached unique commit, dirty tree or failed preservation check must survive. Preserve an unmerged branch; routine branch deletion is allowed only for an owned branch proven merged into the intended integration target, with normal non-forcing deletion.
- Disposable review copies/probes may be deleted after their consumers finish because they are explicitly copies, not the only location of deliverable changes. A writer workspace must not be misclassified as a disposable review copy.
- A paused, failed or interrupted task is retained with a concise recovery pointer. Do not erase the only patch or remaining evidence needed to resume. Stale task state is not automatic permission to delete it.
- Cleanup is idempotent. Partial failures leave enough state to retry; a failed deletion is reported accurately. A successful task should leave no task-owned worktrees/copies/review documents without a concrete preservation reason. Cleanup does not generate another persistent cleanup report.

Prefer existing worktree ownership/integration mechanisms when safe; do not broaden their force-removal recovery paths into a general janitor. A helper and thin lifecycle adapters are sufficient; this is not a new scheduler, agent protocol or merge engine.

## 6. Distribution and FTApp migration

Update the shared skill entrypoint and detailed reference so Simple/Standard paths can stop reading before Full-only role briefs. Update framework role/global templates and worktree/finish guidance wherever they otherwise force full review or ask for routine cleanup permission. Keep general optional review commands available.

`templates/cadence-global-block.md` and `skills/cadence/references/global-block.md` must remain identical, or be replaced by one authoritative source resolved consistently by both installer and initializer. Machine-global and project-local path-selection text must explicitly branch on `workflow: proportional`; missing/legacy workflow keeps the legacy sequence, and disabled/absent cadence stays inert. Installing new global instructions must not silently migrate other projects. Test both source and copied-skill initialization and their rendered instructions against proportional, legacy and disabled configurations.

Ship the same policy and cleanup helper in Claude plugin, linked/copied installs, and Codex's copied skill and hook registrations. Test installed behavior, not only source-file presence. Preserve unrelated hooks, settings and user text; reinstall must be idempotent. Determine the actual installed Claude plugin location before refreshing it. Do not silently alter model/effort choices or disable safety guards.

For FTApp, update LAWS.md, CODEX.md, the cadence configuration, both applicable AGENTS.md/CLAUDE.md instruction blocks, and the copied Git checker as a single reviewed policy migration. Preserve the build prohibition, native file ownership, provider rules, unrelated edits and all non-cadence instructions. Update only the intended sections; do not run a generic initializer over tailored project policy.

Protected policy changes follow the existing authorized amendment mechanism: select the next unused ruling, record the approved change, apply/re-lock in a session the user launched with the required unlock, and use a ruling-bearing commit when the user authorizes that commit. The agent must not set/persist unlock switches or evade the file guard. Prepare a complete reviewed migration before requesting any remaining application approval. Changed Codex hook definitions may require the user's `/hooks` trust step in a fresh session; installation is not trust evidence.

## 7. Acceptance matrix

1. Toast removal: Simple path, relevant checks, no agents/worktrees/repository reports required.
2. Bounded state fix: Standard, one independent review, appropriate regression check; no automatic Full pipeline.
3. Complex policy or multi-system migration: Full, two independent reviews and resolution; requested Claude/Codex diversity honored.
4. Small sensitive edit is not auto-Simple; a large mechanical change is not auto-Full. Scope growth escalates with a concrete reason.
5. Proportional ticket commit succeeds without report files when lock/ruling conditions are met; legacy behavior remains test-covered. Historical audits survive transient artifact deletion.
6. In both harnesses, failed/stale/empty checks remain unverified; focused passing checks count. Discussion/report cleanup after another actor's commit does not demand rerunning app tests. Pending source obligations and failed checks survive intervening discussion/turns. Valid evidence survives a content-preserving commit, while changes to covered source/tests/configuration invalidate it. Supported delegated evidence is reused only with trustworthy task, execution and source provenance; prose/foreign-session evidence is rejected. Missing or inactive hooks never produce a fabricated passing verdict, including in a newly initialized proportional project.
7. Completed owned scratch/review copy is removed; another task's scratch, active consumer, dirty/untracked/ignored-content worktree, locked worktree, detached unique commit, unmerged sole-copy work and symlink/path escape are preserved.
8. A clean owned worktree whose commits are retained can be removed safely; an unmerged retained branch is not deleted. Repeated cleanup is safe.
9. Stop during active/paused work never deletes its resources. Interrupted cleanup retries only the already completed task. Live verification artifacts survive until consumed. Deterministic concurrency tests cover finish versus consumer acquisition, finish versus resource registration, concurrent finish calls and partial-cleanup retry; each proves that only one permitted lifecycle transition wins and active consumers retain their resources.
10. Source and installed Claude/Codex paths agree, reinstall preserves unrelated configuration, and no build/installation of app dependencies occurs.
11. FTApp's lock matches the migrated rules and the required ruling is recorded. If application/trust/authentication is unavailable, report the specific pending step without claiming activation.
12. The first relevant check on Simple/Standard Codex paths uses the trusted runner and needs no duplicate invocation. Both proportional gates accept the shared completion vocabulary; NOT APPLICABLE cannot clear failed/unknown/required outstanding validation. A fingerprint failure preserves the observed failed check or pending invocation. Scope fixtures distinguish in-scope changes, out-of-scope changes and unresolvable writes; an unknown-profile/empty-globs fixture remains PENDING rather than treating an empty fingerprint as reusable evidence. The migration commit uses the staged workflow only after its lock/ruling checks pass, and both global-block installation paths preserve legacy routing.

## 8. Delivery sequence

Draft this spec; obtain an independent spec review and resolve gaps before implementation. Implement against the revised spec with meaningful non-build regression tests. Run independent blind implementation reviews from a Claude agent and a Codex agent; adjudicate findings, fix them and obtain focused re-review of changed contracts. Verify the final combined changes and installed layouts. Apply the protected FTApp migration and refresh the framework installations only through authorized mechanisms. Retain this maintained spec, remove task-owned transient resources after their consumers finish, and deliver a short result with any genuine remaining prerequisites.
