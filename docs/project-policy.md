# Project policy without Cadence

An optional `.llm-orchestrator.json` at the Git root configures deterministic
launches, capacity and test commands. It does not activate Cadence or install
branch protection. Existing projects without this file retain their model and
launch defaults. Configuration errors never select a replacement model.

Use Python 3.11 or later and the installed provider CLIs. The control entry
point is `python3 scripts/lib/orch-control.py` in the plugin source or installed
copy. It has `validate`, `session`, `doctor`, `launch` and `capacity` commands.

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
    "unit": {"argv": ["node", "--test", "tests/example.test.mjs"]}
  }
}
```

The model in this example is an identifier, not an availability promise. This
example configures Codex only. `orch-review.py` can plan its reviewers, prover,
refuter and, when Codex is not signed in, a Claude runner on every installed and
signed-in CLI, so if Claude is also signed in, add Claude `reviewer`, `prover`,
`refuter` and `runner` (or `clerical`) profiles and a Claude catalog too;
otherwise the review stops at preflight. It never picks another model instead.
`validate` asks the review's own plan which roles it may need and lists the
signed-in providers that lack one in `review_profiles_missing`, and, separately,
installed CLIs that are signed out now and would need profiles once they sign
in, in `review_profiles_missing_if_signed_in`.
Validate against the target account's current catalog before launch:

```sh
python3 scripts/lib/orch-control.py validate --project /path/to/project
python3 scripts/lib/orch-control.py doctor --project /path/to/project
python3 scripts/lib/orch-control.py session --project /path/to/project
python3 scripts/lib/orch-control.py launch --project /path/to/project --provider codex --role writer --prompt "Inspect the assigned task and report its next step."
```

`launch` appends one row per attempt to the existing review-outcomes log: the
intended and served model and effort, tokens and cost when the provider reports
them, and any `--delivery-id` you pass. Costs the provider does not report stay
unknown; token counts are not turned into invented dollar figures.

## Models, reasoning and policy loading

Configured launches pass the actual model and effort as CLI arguments. Codex
review sets both `model` and `review_model`; exec uses `--model`. The existing
review/prover/refuter/runner pipeline consumes the same policy, but a review
reads `.llm-orchestrator.json` and the listed policy documents from the
merge-base commit, never from the change it reviews, so a change cannot coach
its own reviewers or pick their models. A policy file that exists only in the
change does not apply to its review. `preflight.json` records `policy_source`:
`merge-base <sha>` whenever the file is at the base, even when it then fails
validation (the error follows in `reasons`), or `none`. The reviewers are told
that the base text is the authoritative copy and that a differing file in the
working tree is part of the change, not policy. Codex reviewers, provers and
refuters also run with `project_doc_max_bytes=0`, so Codex does not load the
copy's own `AGENTS.md` by itself; your personal `~/.codex/AGENTS.md` still
loads. A policy name must be a file: one ending in `/` is rejected.
A configured full Claude ID such as `claude-opus-4-5` also accepts its dated
release, such as `claude-opus-4-5-20251101`. Role defaults
are medium for lead/writer, high for reviewer/debugger/prover/refuter and low
for clerical/runner. `xhigh`, `max` and `ultra` require explicit justification
and must also be advertised by the selected model. No automatic escalation.

`catalogs.codex.path` defaults to the CLI's model cache under `CODEX_HOME` or
`~/.codex`. A catalog is a reading taken on this machine, so it lives outside
the repository and is always read from disk, for a review too. A configured
path is resolved against the project root, and a relative `CODEX_HOME` against
the current directory. The file read is the real one, with links resolved
before any `..`. When that real file is inside the project it is refused, with
an error naming the entry as written and the real path; a link in the project
that leads outside is allowed, because the file it reads is outside. An observation needs a timezone-aware `fetched_at`, matching
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

## Test commands

`checks.<name>.argv` is the exact command of one of your tests, for example
`"unit": {"argv": ["node", "--test"]}`. The Claude Code and Codex completion
checks count that command, and Node's `node --test`, as a check even when
Cadence is off. Help, list, syntax-only and echoed command text do not count.
The completion check still only warns about a claim; it is not proof of
coverage. `argv` is the only key a check takes. No receipt is written in this
release; any other key fails validation and says receipts are not part of it.

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
delivery ID links attempts in the outcomes log; it never certifies delivery.
This release does not count deliveries or cost per delivery, so plans, passing
local checks and opened PRs are never counted as deliveries.

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
change path. Keep review history. Restore no unrelated
project settings, Cadence constitution, hook profile or GitHub protection.
