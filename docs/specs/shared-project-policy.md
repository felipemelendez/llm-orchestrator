# Shared project policy, launches and verification evidence

## Contract

Provide opt-in, deterministic project capabilities independently of Cadence.
Do not change protected rules, activate Cadence, change repository protection,
or change model defaults for projects without the new configuration.
Canonical data configuration is `.llm-orchestrator.json` at a Git root. It
references existing policy documents rather than copying their instructions.
Malformed/unknown keys, unsupported model/effort combinations and unavailable
models fail explicitly before configured model launches; no silent fallback.

## Launches and capacity

Resolve provider-specific role settings for lead, writer, reviewer, debugger,
clerical and existing review helper roles. Start lead/writer at medium,
reviewer/debugger at high, clerical at low; xhigh and stronger efforts require
an explicit justification. Resolve Codex model identifiers and supported efforts
from the CLI's model catalog, with freshness/provenance recorded; an observed
catalog is not proof of a successful remote inference. Claude configuration
must validate against explicit observed provider capabilities rather than
invent equivalent effort values. Preserve legacy behavior without policy.

Apply resolved settings to actual `codex exec`, `codex review`, Claude review
and helper command arguments. A review reads `.llm-orchestrator.json` and every
listed policy document from the merge-base revision, never from the working
tree under review, and records `policy_source` (`merge-base <sha>` or `none`).
Without the file at the base the review runs without policy. Explicit
`orch-control.py` commands read the working tree; they are not reviews. Preserve authentication, sandbox, MCP isolation,
dropout and served-model validation. Record intended settings separately from
observed settings. Include role-configured general launch entry points so
lead/writer settings are executable rather than advisory.

One cross-process, locked capacity ledger shared across configured projects covers plugin-managed inference
launches and review helpers, including review/prover/refuter/runner stages.
All worktrees and configured projects use the same ledger and must agree on
its budget. Its unit is one managed outer CLI process; record the reserved
external occupancy separately. Do not describe this as a hard cap on inference
fanout. Claude /code-review and host/provider-native subagents are not bounded
by this unit. A requested hard inference cap must decline such a launch with
an actionable error, keeping any required review incomplete.
Explicitly reserve externally occupied slots, fail or wait for a bounded time
on exhaustion, release on failure/timeout, and never treat admission as a
successful review. An untrusted/missing hook does not disable explicit APIs.
Document native host subagents, manually launched CLIs and hidden provider
fanout as outside deterministic control; do not claim a universal process cap.

## Evidence and checks

Extend existing completion check recognition with Node's built-in test runner
and exact configured custom command argv, without requiring Cadence. Reject
Node help/list/syntax-only modes. Preserve existing warning semantics.

An explicit check runner records the actual argv, working directory, start/end,
exit code, output digest, repository/worktree identity, source scope and
configuration fingerprints, environment fingerprint and revision. Receipts
live outside Git. Reuse requires a complete successful receipt, matching check
definition, same project, identical scoped file content and configuration,
identical declared environment/toolchain, and unchanged supported inputs.
Capture dirty/untracked scoped inputs. Reusable checks run in task-owned,
isolated snapshots with OS-enforced read-only source inputs through the
existing Codex sandbox; verify a write probe is refused before execution.
If this sandbox is unavailable, snapshots require unsupported dependencies,
or source immutability cannot be established, checks may still execute but
their receipts are explicitly ineligible for reuse. Pre/post hashes alone
are not proof against edit-and-restore (ABA) mutation. Reject symlink,
submodule and external inputs inside the declared scope; ones outside it do not
block a check. A declared directory covers every file under it. A
project-relative executable resolves against the project and is an input.
A reusable receipt needs output showing at least one test ran: recognised
zero-test or collection-only output is rejected, and a known test runner whose
output cannot be judged records `tests_ran: unknown` and is not reusable.
Receipts are read only to reuse one; an unreadable receipt is skipped, named in
the result, and disables reuse for that run. An interrupted check stops the
run and is recorded as failed. After a sandbox fallback the receipt records the
environment that actually ran. Changed revision alone is permitted if
covered inputs are identical. Reject changed inputs, stale/missing environment,
incomplete/failed/tampered receipts and mutations during a check. Record failed
and actual repeated executions; a newer failure is not erased by an old pass.
Never reuse independent review, required hosted CI or final non-author approval
as a software check. Scope is a declared coverage boundary, not proof that the
test covers all behavior. Mandatory current checks can opt out of reuse.

## Sessions, diagnostics and measurement

Fresh configured launches load the referenced policy files and their hashes.
Expose an explicit session/diagnostic command for hosts lacking a trusted
SessionStart hook; use existing startup integration where possible. A doctor
reports source/install parity, config/catalog validation, Cadence status,
hook declarations versus observed trust, and uncontrolled launch paths without
claiming unobservable hook execution. No service, daemon or extra LLM call.

Extend existing usage/outcome mechanisms with intended/observed role settings,
tokens/provider-reported cost when available, capacity wait (`capacity_wait_s`,
unknown when no launch recorded one), checks executed
or reused, repeated work, and explicit delivery IDs. Aggregate cost per
validated delivery only from linked observed receipts, preserving unknown
costs and failed attempts. No invented dollar prices or performance improvement.
An independent review verdict alone is not a validated delivery. Until an
exact-revision, non-author final gate and all required check receipts plus
delivery integration evidence can be authenticated from existing outcomes,
report delivery cost as pending and validated-delivery count as unknown/zero.
Never accept a caller-supplied `validated` boolean as that transition. Prefer
honest pending measurement to another approval/attestation service.

## Mia adoption

Configure shared capabilities through project data and links to the existing
canonical policies. Preserve independent review counts, blocking-defect handling,
ownership, two active tasks plus one externally blocked allowance, one integrator,
exact-revision merge/post-merge gates and GitHub handoff ownership. Model capacity
is distinct from ticket WIP. Keep Cadence activation and protected GitHub changes
pending separately. Do not edit unrelated projects or add a tracked live board.

## Acceptance and validation

Regression tests cover a generic non-Mia fixture and Mia-shaped policy; fresh
session loading; argv for review/exec and helpers; invalid/unavailable models
and efforts; shared capacity under concurrent processes and failure; changed
revision with identical inputs, stale environment, dirty/untracked changes,
mutations, failure shadowing and malformed receipts; Node/custom recognition;
disabled hooks; honest usage aggregation and install diagnostics. Fixtures use
fake CLIs for deterministic failure coverage, and are labeled synthetic.
Perform bounded live exec/review served-model/effort checks and Claude built-in
review where available, and report their exact
scope. Existing applicable suites must continue to pass. Obtain independent
spec review before implementation, the required two blind built-in reviews
for finished plugin changes, and non-author final verification. Missing review
or execution remains incomplete, never agreement.

Document exact source revision, update procedure, byte-parity verification,
rollback and any changed hook trust requirement. Update installation only after
source validation; preserve prior installed artifacts and do not alter unrelated
projects' settings. User authorization covers implementation, tests, reviews,
installation update and verification; repository-specific commit/merge authority
is handled separately.
