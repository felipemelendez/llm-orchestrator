# Project policy without Cadence

An optional `.llm-orchestrator.json` at the Git root configures deterministic
launches, capacity and check receipts. It does not activate Cadence or install
branch protection. Existing projects without this file retain their model and
launch defaults. Configuration errors never select a replacement model.

Use Python 3.11 or later and the installed provider CLIs. The control entry
point is `python3 scripts/lib/orch-control.py` in the plugin source or installed
copy. It has `validate`, `session`, `doctor`, `launch`, `capacity`, `check` and `usage` commands.

## A minimal project

```json
{
  "schema": 1,
  "policies": ["AGENTS.md"],
  "roles": {
    "codex": {
      "lead": {"model": "gpt-6.1-sol", "effort": "medium"},
      "writer": {"model": "gpt-6.1-sol", "effort": "medium"},
      "reviewer": {"model": "gpt-6.1-sol", "effort": "high"},
      "debugger": {"model": "gpt-6.1-sol", "effort": "high"},
      "clerical": {"model": "gpt-6.1-sol", "effort": "low"}
    }
  },
  "capacity": {"max_processes": 4, "external_slots": 1, "wait_timeout_s": 30},
  "checks": {
    "unit": {
      "argv": ["node", "--test", "tests/example.test.mjs"],
      "inputs": ["**"],
      "environment": [],
      "tools": ["node", "codex"],
      "timeout_s": 120,
      "reuse": true,
      "immutable": true
    }
  }
}
```

The model in this example is an identifier, not an availability promise. This
example configures Codex only. `orch-review.py` can plan its reviewers, prover
and refuter on every installed CLI, so if Claude is also installed, add Claude
`reviewer`, `prover` and `refuter` profiles and a Claude catalog too; otherwise
the review stops at preflight. It never picks another model instead. `validate`
lists installed providers that lack these profiles in `review_profiles_missing`.
Validate against the target account's current catalog before launch:

```sh
python3 scripts/lib/orch-control.py validate --project /path/to/project
python3 scripts/lib/orch-control.py doctor --project /path/to/project
python3 scripts/lib/orch-control.py session --project /path/to/project
python3 scripts/lib/orch-control.py launch --project /path/to/project --provider codex --role writer --prompt "Inspect the assigned task and report its next step."
python3 scripts/lib/orch-control.py check --project /path/to/project --name unit --reuse
python3 scripts/lib/orch-control.py usage --project /path/to/project
```

The last command reports observed attempts, grouped intended/served role profiles,
tokens and known/unknown costs, total capacity wait (`capacity_wait_s`, null when
no launch recorded one), plus caller-linked delivery attempts. It does not label an unmerged or
unverified result a validated delivery. Repeated same-revision executions include legitimate invalidations and failures;
they are not automatically avoidable work. Costs absent from provider output remain
unknown; token counts are not converted into invented dollar estimates.

## Models, reasoning and policy loading

Configured launches pass the actual model and effort as CLI arguments. Codex
review sets both `model` and `review_model`; exec uses `--model`. The existing
review/prover/refuter/runner pipeline consumes the same policy, but a review
reads `.llm-orchestrator.json` and the listed policy documents from the
merge-base commit, never from the change it reviews, so a change cannot coach
its own reviewers or pick their models. A policy file that exists only in the
change does not apply to its review; `preflight.json` records `policy_source`.
A configured full Claude ID such as `claude-opus-4-5` also accepts its dated
release, such as `claude-opus-4-5-20251101`. Role defaults
are medium for lead/writer, high for reviewer/debugger/prover/refuter and low
for clerical/runner. `xhigh`, `max` and `ultra` require explicit justification
and must also be advertised by the selected model. No automatic escalation.

`catalogs.codex.path` defaults to the CLI's model cache under `CODEX_HOME` or
`~/.codex`. An observation needs a timezone-aware `fetched_at`, matching
`client_version`, and the model's advertised `supported_reasoning_levels`.
Default maximum age is one day; configuration can shorten it. A catalog is
local capability evidence, not a successful remote inference. Authentication,
rate limits and service availability can still make a launch incomplete.

Claude requires an explicit observed capability catalog, with `fetched_at`,
`client_version`, descriptive `provenance`, and `models` entries containing
`slug` and `supported_reasoning_levels: [{"effort": "high"}]`. Record only
identifiers/aliases and efforts supported by actual provider/CLI observations;
do not translate Codex efforts into Claude values. CLI help establishes accepted
option values; provider result/usage establishes the served model. If served
effort is not exposed, report it as unknown. Refresh through those observations
rather than extending a timestamp without rechecking.

`session` freshly reads linked canonical policy documents and returns their text
and hashes. Configured plugin launches inject those current documents. On a
fresh native Claude session, the existing SessionStart hook freshly reads policy
on startup/clear/resume/compact, independent of Cadence. Small policies include
text and hashes. Oversized policies explicitly report that full text is NOT
loaded into model context and give a hashed manifest plus required file-read
directive within the context limit. A disabled hook does nothing. In Codex run
`session` explicitly and read the returned policy; its manifest has no SessionStart
loader. Manual host launches cannot be
forced through this command. Disabled/untrusted hooks do not disable explicit
configuration validation, launch admission or check execution. `doctor` separates
hook declarations from unobserved trust; it cannot attest that a host ran a hook.

## Capacity boundary

One locked state ledger under `XDG_STATE_HOME/llm-orchestrator` (normally
`~/.local/state/llm-orchestrator`) is shared across configured projects and their
worktrees. Configurations must agree on the budget. Four maximum slots with one
external reservation admit three managed outer CLI processes. Exhaustion waits
for the configured bounded interval and then reports an error. It is never an
approval or a successful review. Tracked child lifetime, failure and uncertain
crash state remain part of admission. Review helper pools are bounded by available
managed slots before dispatch. A durable admitted/spawning/attached phase permits
safe reclamation when a dead owner never reached spawn. A dead owner in the spawn
attachment gap remains uncertain and retains its slot; a PID or age alone never
proves that unobserved children stopped. `capacity status` explains retained leases.

A budget change requires explicit reconciliation while the ledger has no leases;
it never silently adopts whichever project launched last:

```sh
python3 scripts/lib/orch-control.py capacity status --project /path/to/project
python3 scripts/lib/orch-control.py capacity reconcile --project /path/to/project --expect-max-processes 4 --expect-external-slots 1
```

The expected values are the old ledger budget; the selected project's current
configuration supplies the new budget. Conflicting projects then fail clearly
until their configuration agrees. There is no guessed orphan-clear command.

The counted unit is an outer CLI process. Native host agents, manually launched
CLIs, `/code-review`'s internal agents and provider fanout are not universally
controllable by this plugin. Reserve external occupancy honestly. A hard
inference-cap request is refused where the CLI cannot prove that bound; a
required review stays incomplete rather than being silently replaced. Projects
without opt-in policy do not participate in this configured ledger. This is not
a cap on every model call on the machine.

## Check receipts and reuse

Node's `node --test` and exact custom check argv are recognized by the existing
Claude/Codex completion checks even when Cadence is absent. Inspection/help,
syntax checking and echoed command text do not establish test execution. The
completion hook still warns about a claim; it is not a coverage certificate.

An explicit `check` records actual completion, scoped working-tree content
(including dirty and nonignored untracked files), command definition, canonical
policy/configuration, platform, declared environment, actual executable bytes and
declared toolchain identity,
output digest and revision. Receipt files are locally signed, outside Git, and
append concise rows to the existing review-outcomes log. Failed/pending newer
attempts prevent borrowing an older success. Reuse also rejects altered output,
unreadable receipts, source/configuration/tool/environment changes and another
repository's receipt. A revision can change while identical declared inputs
remain eligible. Coverage depends on the declared scope; start with `**` when
dependencies are uncertain. A directory input such as `src` covers every file
under it. A project-relative command such as `./scripts/check.sh` runs the
project's own file, which is then part of the scope. Receipts are read only when
reuse is asked for; a receipt that cannot be read is skipped, named under
`skipped_receipts`, and that run executes fresh. Pressing Ctrl-C stops the
check and the run, and the receipt is marked failed.

Reusable checks require a task-owned source snapshot through the existing
resource manager and a demonstrated OS read-only sandbox. Pre/post hashes alone
cannot establish immutability against edit-and-restore. The sandbox probe must
actually refuse a source write and an external-input read. Only declared source
inputs are materialized; user Git configuration and user Python site packages
are isolated. Tests receive their own writable home and temporary directory.
Opaque inline interpreters, common command wrappers and absolute external data
arguments run record-only. Version probes use an absolute owned temporary home;
stable hash placeholders are never passed as real paths.
Wholly skipped/todo or empty Node suites cannot supply reusable evidence, and
neither can zero-test or collection-only runs (unittest `Ran 0 tests`, pytest
`no tests ran`, `collected 0 items` or `--collect-only`, Node `# tests 0`, go
`[no test files]`). The receipt's `tests_ran` says `true`, `false`, `unknown`
(a known test runner whose output cannot be judged: not reusable) or `custom`
(an exact configured command that is not a known test runner, judged by exit
code and nonempty output).
A state directory inside a writable temporary root is
not eligible. Symlinks, submodules and external inputs inside the scope are
rejected; ones outside it do not block a check. A sandbox fallback records the
environment that actually ran.
Ignored dependencies are deliberately not copied into source snapshots. A check
requiring those dependencies must run without reuse until it has a supported,
fingerprinted immutable execution environment. The minimal OS sandbox can deny third-party runtimes (including Homebrew Node)
and network access. Select `immutable: false, reuse: false` for such checks rather
than broadening the read boundary. Node built-in checks still execute and record
results without Cadence. Build output, browser artifacts and hosted CI usually
need separate execution paths.

If the sandbox is unavailable, the command can execute in record-only mode in
the real project. Its receipt clearly says reuse is unavailable. Hook absence
cannot silently turn this into a reusable pass. `reuse: false` always requires a
new execution. Independent review, required hosted CI and final non-author
verification cannot be replaced by a local reused software check.

This is local execution evidence, not a defense against a determined process
that replaces the CLI, steals the signing key or edits another session's owned
snapshot. Source policy, installation trust and operating-system isolation
remain separate boundaries.

## Project differences and delivery measurements

`project_rules` validates explicit review/WIP/delivery obligations while canonical
policy prose retains authority. The supported shape is:

```json
{
  "review": {
    "minimum_independent_reviews": 1,
    "high_risk_independent_reviews": 2,
    "non_author_final_verification": true,
    "confirmed_defects_block": true
  },
  "wip": {"active": 2, "parked": 1, "total": 3},
  "delivery": {
    "merge_method": "squash",
    "handoff": "github",
    "exact_revision": true,
    "post_merge_verification": true
  }
}
```

Types and invariant relationships are checked. These data do not inspect GitHub
WIP, merge a PR, grant authority or authenticate a non-author final integration
gate. The coordinator must still apply those obligations. A caller-supplied
delivery ID links costs/attempts; it never certifies delivery. Until exact
delivery and independent final gates can be authenticated from maintained
evidence, `validated_deliveries` and cost per validated delivery stay unknown.
This prevents counting plans, passing local checks or opened PRs as deliveries.

## Update, verify and roll back

Keep implementation in a maintained source checkout, review it and run its
required suites before updating installations. Normal released updates use the
existing installers:

```sh
codex plugin add llm-orchestrator@llm-orchestrator
claude plugin update llm-orchestrator@llm-orchestrator
```

Those commands use the configured marketplace, not arbitrary uncommitted edits.
For a development snapshot, first preserve the installed plugin in a fresh
external backup, then refresh its shipped files from the validated source.
Record source HEAD, complete diff/content digest and destination. Do not call
an uncommitted snapshot a published release or point a permanent marketplace at
disposable scratch. Never overwrite installation edits without inspecting them.

From the maintained source, verify the actual copy:

```sh
python3 scripts/lib/orch-control.py doctor --project /path/to/project --installed-root /path/to/installed/plugin
```

Require byte parity, then invoke the installed `orch-control.py` and repeat a
fresh-session load, a configured launch and relevant checks. New/changed hook
definitions require renewed host trust; installation alone is not trust.

Rollback restores that exact preserved installation, verifies its saved hashes,
and removes this project's opt-in configuration through its normal reviewed
change path. Keep execution receipts and review history. Restore no unrelated
project settings, Cadence constitution, hook profile or GitHub protection.
