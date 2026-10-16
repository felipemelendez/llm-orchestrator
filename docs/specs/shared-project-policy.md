# Shared project policy and launches

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
tree under review, and records `policy_source`: `merge-base <sha>` whenever the
file is at the base, even if it then fails validation, else `none`. Without the
file at the base the review runs without policy. A capability catalog is a
reading of this machine, never part of the revision: it is always read from
disk, a configured path resolved against the project root and the `CODEX_HOME`
default against the current directory. One rule applies to one path: the
path's real location, with links resolved before any `..`, is refused when it
or a folder above it is the project root by file identity, so another spelling
of the project folder on a case-insensitive disk is still the project, and a
link in the project that leads outside reads an outside file and is allowed.
The refusal names the entry as written and the real path it reads. The injected text says the base copy is
authoritative and a differing working-tree file is part of the change. Codex
review launches pass `-c project_doc_max_bytes=0` so Codex does not load the
copy's `AGENTS.md` itself; the user's global `~/.codex/AGENTS.md` still loads.
A listed policy name ending in `/` is rejected. Explicit
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

A check is `checks.<name>.argv`, the exact command the completion check
recognises, and nothing else; any other key under a check fails validation
and says receipts are not part of this release.

Later, behind its own spec: a check runner that writes a record of what ran
(command, files, environment, output). It returns when something consumes it.

## Sessions, diagnostics and measurement

Fresh configured launches load the referenced policy files and their hashes.
Expose an explicit session/diagnostic command for hosts lacking a trusted
SessionStart hook; use existing startup integration where possible. A doctor
reports source/install parity, config/catalog validation, Cadence status,
hook declarations versus observed trust, and uncontrolled launch paths without
claiming unobservable hook execution. No service, daemon or extra LLM call.

A configured launch appends its attempt to the existing review-outcomes log:
intended and observed role settings, tokens and provider-reported cost when
available, and an explicit delivery ID when given. Unknown costs stay unknown;
no invented dollar prices. This release counts no deliveries and no cost per
delivery; a review verdict or a caller-supplied flag is never a delivery.

## Mia adoption

Configure shared capabilities through project data and links to the existing
canonical policies. Preserve independent review counts, blocking-defect handling,
ownership, one integrator,
exact-revision merge/post-merge gates and GitHub handoff ownership. Model capacity
is distinct from ticket WIP. Keep Cadence activation and protected GitHub changes
pending separately. Do not edit unrelated projects or add a tracked live board.

## Acceptance and validation

Regression tests cover a generic non-Mia fixture and Mia-shaped policy; fresh
session loading; argv for review/exec and helpers; invalid/unavailable models
and efforts; shared capacity under concurrent processes and failure; check keys other
than `argv` rejected by name; catalogs refused when their real path is inside the project, by file
identity; Node/custom recognition (`tests/test-policy.sh`); disabled hooks; launch
outcome rows and install diagnostics. Fixtures use
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

## Settled

- **Receipts record; they do not reuse.** No reader of runner output can prove
  a test body ran (Node counts an empty file as one passing test; a module can
  print a fake summary). Reuse returns one runner at a time behind its own spec.
- **The catalog lives outside the repository.** It is a reading of this
  machine, so it is read from disk and refused inside the project root.
- **Receipts are not in 0.16.0.** Four review rounds each found new reproduced
  defects in the receipt code; it returns when something consumes it, behind
  its own spec.
