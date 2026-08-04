# Researcher dispatch envelope

Paste this filled in as the `orch-researcher` subagent's prompt. Paste the
**content**, never a file path — the subagent cannot reliably resolve paths
relative to the plugin root.

`agents/orch-researcher.md` returns `Status: BLOCKED` when a field is missing,
so every slot below needs a value. Write `unspecified` rather than deleting a
line — "we don't know the version" is information; a missing line is not.

```
Task text: <what the user actually asked for, verbatim>

Trigger point: <A (pre-spec) | B (pre-plan)>

Proposed Approach:
<the spec's ## Approach section if Trigger B; the user's framing if Trigger A>

Libraries: <name@version, comma-separated; "unspecified" where no version is pinned>

Stakes: <low | medium | high>

Capability survey:
<What research tooling this install actually has. Do not guess from the list in
the agent file — call ToolSearch (one call, comma-separated) or check the
session's connected MCP servers, and paste what came back. "Only WebFetch and
WebSearch" is a valid and useful answer; it sets the depth the researcher can
honestly reach.>

Brief output path: docs/llm-orchestrator/research/<YYYY-MM-DD>-<slug>-brief.md

Cache root: ~/.llm-orchestrator/research/cache/<project-hash>/
```

## Filling the last two

```bash
# project-hash — same function every hook uses, so the cache lands where the
# gate later looks for it.
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
L=$(orch_lib orch-project.sh) && . "$L" && orch_project_hash
date +%F   # the brief's date prefix
```

## Where the values come from

| Slot | Source |
|---|---|
| Task text | the user's message |
| Trigger point | `research-classifier` output, or A when invoked directly |
| Proposed Approach | the spec, or the user's framing |
| Libraries, Stakes | `research-classifier` output |
| Capability survey | `ToolSearch` / connected MCP servers, checked at dispatch time |
| Brief output path | `docs/llm-orchestrator/research/` + today + a slug |
| Cache root | `orch_project_hash` (above) |

## Why this file exists

`commands/research.md` used to say "dispatch the researcher with
`templates/research-brief.md`". That file is the **output artifact** template —
the shape of the brief the researcher writes — not a dispatch envelope, and the
three things the command told you to paste covered two of the eight required
fields. The classifier supplies four. Trigger point, Stakes, Capability survey,
Brief output path and Cache root were assembled nowhere, so a researcher
following its own contract had to return `BLOCKED`, and one that didn't was
ignoring its own envelope contract.
