# Test suite

Three scripts. Run them in this order before any commit:

```bash
./tests/validate-skills.sh     # 1. structural: frontmatter, names, length
./tests/test-portability.sh    # 2. portability: bash 3.2 / BSD / macOS safe
./tests/smoke.sh               # 3. behavior: hooks, lock, install, classifier
```

All three should exit 0 with green output. If any fails, fix before committing.

## What each one checks

### `validate-skills.sh` — structural validator

Verifies the static shape of every skill, command, and agent file. Catches typos and frontmatter drift before they reach users.

Checks per **skill** (`skills/<name>/SKILL.md`):
- Frontmatter has `name` + `description`
- Directory name matches `name:` field
- `description` starts with "Use when"
- File is ≤ 250 lines (cap)
- No 4+ consecutive ALL-CAPS words outside code fences
- Any `templates/<file>` references resolve to a real file

Checks per **command** (`commands/<name>.md`):
- Frontmatter `description` present
- Any backticked skill names match an existing skill directory

Checks per **agent** (`agents/<name>.md`):
- Filename matches `name:` field
- `description` present
- `model:` (if set) is one of `haiku | sonnet | opus`

Output: `OK: 16 skills, 11 commands, 8 agents` on success. Otherwise lines starting with `FAIL:` and exit 1.

### `test-portability.sh` — shell portability scanner

Static scan of every shell script and command body. Flags constructs that work on Linux+GNU but break on macOS (default bash 3.2 + BSD coreutils).

Hard fails on:
- `mapfile` / `readarray` (bash 4+ only)
- `declare -A` (associative arrays; bash 4+)
- `grep -P` (PCRE; GNU-only)
- `date -d` (GNU-only date arithmetic)
- `readlink -f` (GNU-only canonical path)
- `${VAR:+$'\n'...}` (the bash 3.2 quote-expansion bug we hit in round 3)
- Commands that use `shasum` without a `sha1sum`/`cksum` fallback

Warns (doesn't fail) on:
- `sed -i` usage — BSD requires `sed -i ''` with empty arg; check it's gated by a `sed --version` probe
- Hardcoded `~/.llm-orchestrator` paths — should be `${ORCH_HOME:-$HOME/.llm-orchestrator}`

Output: 7 checks pass on success, warnings listed informationally.

### `smoke.sh` — behavior smoke test

Exercises everything that can be tested without a live Claude Code session. Bash 3.2 compatible; runs in ~5 seconds.

Six sections:

1. **Structural** — delegates to `install.sh --check` and `validate-skills.sh`.
2. **Hooks** — runs each hook with realistic inputs:
   - SessionStart → valid JSON, loads the using-orchestrator meta-skill body
   - UserPromptSubmit → valid JSON, reminder mentions the protocol
   - PreToolUse guard → blocks `--no-verify` (exit 2), allows clean commits (exit 0)
   - SubagentStop → accepts both markdown and JSONL transcripts with a `Status:` block, warns (exit 0) when missing
   - Stop hook → prunes `memory/.trash/` older than retention
3. **Portable lock** — sources `scripts/lib/orch-lock.sh`, runs 10 concurrent writers, expects 10 lines; tests `append_line` for shell-injection safety.
4. **Classifier** — runs the `/remember` section classifier on 9 canonical facts (`pnpm not npm` → Conventions; `Sara owns auth` → People; `we picked tRPC over GraphQL` → Decisions; etc.). Each fact must land in the expected section.
5. **--copy install** — runs `install.sh --copy` against a fresh git project, verifies every required file landed (`scripts/lib/orch-lock.sh`, `settings.json`, `output-styles/`, `concise-agent-protocol.md`, etc.), checks the generated `settings.json` is valid JSON, checks `hooks.json` paths are absolute, re-runs SessionStart from the copied install.
6. **Documentation** — no stale `OrchestraKit`/`OK_` identifiers remain, README has the Quick Start block, no auto-loading `.mcp.json` is present (only `.mcp.json.example`).

Flags:
- `--quiet` — only print failures and the summary line.
- `--section <name>` — run a single section (one of `structural | hooks | lock | classifier | install | docs`).

Output: per-check `✓` or `✗`, then a summary line. Exit 0 if all green, 1 if any fails.

## What these tests do NOT cover

These scripts catch every bug we can find without involving Claude Code itself. They do **not** verify:

- That Claude Code actually loads the plugin via `/plugin install`
- That the meta-skill body the agent receives produces the right behavior (e.g., agent replies in shape blocks)
- That subagent dispatches actually return well-formed Status blocks
- End-to-end orchestration across `/plan → /dispatch → /review → /verify → /finish`
- Memory loading inside a real session
- The statusline rendering inside the Claude Code UI

For those, install the plugin (`./scripts/install.sh --link` then `/plugin install llm-orchestrator` in a Claude Code session) and use it on a real task. The README's Quick Start has the full flow.

## When to add a new test

Add a check to `smoke.sh` when:
- A bug reaches production (or a reviewer) — add a check that would have caught it.
- A new hook, script, or behavior ships — add a section.
- Output format changes (e.g., a new Status enum value, a new section in memory files).

Add to `validate-skills.sh` when:
- A new skill/command/agent convention is enforced (e.g., a required body section).

Add to `test-portability.sh` when:
- You discover another GNU/Linux-only construct that the team's reviewers caught.

## CI integration (future)

These scripts are designed to run in CI. A simple `.github/workflows/test.yml` would be:

```yaml
- run: ./tests/validate-skills.sh
- run: ./tests/test-portability.sh
- run: ./tests/smoke.sh
```

All three exit non-zero on failure; CI fails the build automatically.
