---
name: handing-off-to-fresh-context
description: Use when the context window is filling and work must transfer cleanly to a fresh session without state loss.
---

# Handing off to fresh context

Regenerate a self-sufficient handoff artifact so a fresh controller resumes long multi-tier work with zero state loss.

## When to use

- **Primary path (from `executing-plans` at a tier boundary):** a tier just completed with a green verify, material work remains, and context is past ~50%. The seam is clean — plan checkboxes accurate, diff reviewed, nothing in flight. Fire here.
- **Fallback — explicit command:** the user runs `/llm-orchestrator:handoff`.
- **Fallback — pressure hook:** the context-pressure hook runs on `UserPromptSubmit` (advisory when context crosses the warn threshold, ~70%) and on `PreCompact` (where, in strict profile only, it blocks an auto-compaction so a handoff can run first — PreCompact can only block, it cannot inject text). After native compaction completes, `session-start.sh` fires with `source=compact` and injects the post-compaction reminder: treat the summary as lossy and re-run the verification baseline. The hook is advisory by default; in strict profile (`ORCH_HOOK_PROFILE=strict` + `ORCH_STRICT_CONTEXT_PRESSURE=1`) it can hard-block the turn at the ~85% ceiling. A strict block is the unavoidable emergency brake — regenerate the handoff immediately, capturing whatever in-flight state exists (note any partial or un-verified items explicitly in the In-flight observations slot), then resume in a fresh session.

## When NOT to use

- Mid-batch with agents in flight, partial diffs, or an unverified suite — finish the batch to a green seam first.
- Short tasks that will finish before context strains.

## Why tier boundaries beat thresholds

Saturating mid-batch leaves state hard to capture: partial diffs, unverified results, agents mid-flight, review pending. Saturating between batches is trivial to hand off: checkboxes accurate, diff reviewed, clean starting point.

**The rule:** if a tier just completed with a green verify and material work remains, fire when context is past ~50% of the window **or** past the absolute handoff floor (`ORCH_CONTEXT_HANDOFF_TOKENS`, default ~120K tokens), whichever comes first — even though that is below the 70% threshold. The absolute floor matters on a 1M-token window, where 50% is 500K — well above the ~150K point at which native auto-compaction kicks in; the token floor makes the seam fire before that. Do not wait for the threshold mid-batch.

**Worked example:** context reaches 55% just after tier 2 green-verify, three tiers remain. Fire now — the seam is clean. If instead the hook fires at 70% while 12 subagent reports are still in flight, the state is tangled and the artifact will be incomplete. The threshold hook is the emergency brake for when no seam will arrive in time, not the primary signal.

## Steps

1. **Resolve the artifact path.** Use `docs/llm-orchestrator/handoffs/<date>-<slug>.md` (same slug as the plan). If the file already exists, this is a regeneration — overwrite in place, bump the revision. Never write a v2 sibling file.

2. **Memory-aware bootstrap.** Read the `## ` sections of `./CLAUDE.md` and `~/.llm-orchestrator/architecture/<hash>/decisions.md` if present (resolve `<hash>` by sourcing `orch-project.sh` and calling `orch_project_hash`, which returns the SHA-1 prefix of the git remote URL, repo root path, or cwd), plus relevant files under `~/.claude/projects/.../memory/`. The artifact's "Memory index" section is generated from these reads, not hand-written.

   Locate plugin libs with this resolver (CLAUDE_PLUGIN_ROOT is often unset in skill bash, and marketplace installs nest under the plugin cache — so fall back to a version-sorted find). Reuse it for every `orch-*.sh` sourced below:

   ```bash
   orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
   L=$(orch_lib orch-project.sh); [ -n "$L" ] && source "$L" || echo "orch-project.sh not found — reinstall the plugin" >&2
   ```

3. **Reconcile plan state.** Open the plan file, count task-heading checkboxes (completed/pending), cross-reference `TaskList` for in-flight tasks. The artifact indexes this state; the plan file and Task tools remain the source of truth — never duplicate or contradict them.

4. **Populate all 10 slots from `templates/handoff.md`.** Paste the last 3–5 subagent reports verbatim (do not summarise). Fill the verification baseline with the exact commands and the expected output from the last green run. For the new `## Active task context` slot: list the specific files and line ranges the next action will touch first (goal-conditioned — so the fresh controller does not have to re-discover them), then list the key conventions and decisions active for this task indexed by heading from CLAUDE.md (do not duplicate CLAUDE.md's text, just cite the heading). This slot is intentionally small; do not dump context into it.

5. **Set frontmatter.** Bump `revision` via `orch-handoff.sh` (source it with the `orch_lib` resolver from step 2: `L=$(orch_lib orch-handoff.sh); source "$L"`) → `orch_handoff_next_revision`. Set `last_regenerated_at` to now (ISO8601). Set `trigger` to `user`, `threshold`, or `tier-boundary`. Set `context_estimate_pct` to the estimate or `unknown`.

6. **No-op check (within-session + cross-session).** Before overwriting an existing artifact, capture its body-hash. After generating the new content, compare: use `orch_handoff_bodies_match` if available, otherwise call `orch_handoff_body_hash` twice and compare the results. If equal, it is a within-session no-op — still write (bump revision + timestamp) but flag it to the user and to the reviewers as a redundant regeneration. For cross-session detection use `orch_handoff_is_noop` (body-hash vs the prior committed revision in git HEAD); note that HEAD comparison never fires on an uncommitted artifact, so the within-session comparison above must run first. **Rollback affordance:** because regeneration is latest-wins, a degraded or accidental regeneration can be rolled back via git — `git checkout HEAD~1 -- <artifact-path>` restores the prior revision, and `git log -- <artifact-path>` shows the full version record. Git history is the version record for handoff artifacts.

7. **Two-stage review on every regeneration.** Dispatch `orch-spec-reviewer` (does the artifact fill every required slot? are all citations live?) then `orch-code-reviewer` (minimal, self-sufficient, no stale references, no ambiguous shorthand). On either failing, revise the artifact and re-review. A no-op regeneration must be flagged by the reviewers.

8. **Hand control off to the user** (see Output shape below).

## Resume contract (fresh controller)

- The fresh controller's first action is to run the artifact's verification baseline commands and confirm the green state. Only after green does it pick up the next task.
- If verification diverges from the artifact's expected output, it does not proceed — it invokes `systematic-debugging` on the divergence first. It never assumes the baseline is current.
- **Lean artifact / size discipline:** the handoff exists to reduce context, not add to it. Cap `## Recent agent reports` to the last 3–5 blocks. If a single report is very long, trim it to its Status/verdict lines and note where the full text lives (git log, transcript) rather than pasting everything. The artifact must not itself become large enough to strain the fresh window.
- **Re-hydration pointer:** the resume prompt must tell the fresh controller where fuller prior context lives — specifically the artifact's git log (`git log -- <artifact-path>`) for version history and the prior session transcript for full agent-report detail. A lean artifact is safe only when that pointer is present.

## Output shape

The protocol decision: reuse existing shapes, no 7th shape.

Regeneration announces as `Changed:`:

```
Changed:
- docs/llm-orchestrator/handoffs/<date>-<slug>.md — revision N, trigger: tier-boundary, context: 55%

Verify:
- spec+code reviewers passed
```

Handing control off announces as `Blocked:`:

```
Blocked:
- Context is too full to continue in this session.

Need:
- Start a fresh session and paste the resume prompt from the artifact.

Tried:
- Regenerated the artifact (vN); spec and code reviewers passed.
```

## Anti-patterns

- Threshold fires at 70% mid-batch with 12 agent reports still un-summarised → bad handoff. Skill fires at 55% after tier 3 green-verify with nothing in flight → great handoff.
- Writing a v2 sibling file instead of overwriting in place.
- Summarising agent reports instead of pasting verbatim.
- Duplicating plan checkbox state in the artifact (the plan file is the source of truth).
- Skipping the two-stage review gate on a regeneration.
- Proceeding on resume without running the verification baseline first.
- Omitting the re-hydration pointer from the resume prompt (a lean artifact is not safe without it).
- Letting the artifact grow large by pasting full reports — trim long reports to their verdict lines and cite git log or the transcript for the rest.
- Forgetting that a bad regeneration is recoverable: `git checkout HEAD~1 -- <artifact-path>` is always available.
