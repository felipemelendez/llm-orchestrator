---
description: Turn the cadence on for this project — laws, lock, deny rules and git hooks. Proposes a cadence.json for you to confirm first.
argument-hint: "[--adopt] [--dry-run]"
---

You are running `/llm-orchestrator:cadence-init`.

User input: $ARGUMENTS (optional — `--adopt` when this project already has its own laws; `--dry-run` to see the plan without writing anything)

This command is the conversation; `cadence-init.sh` is the mechanism. Your job is
to get the project's `cadence.json` right with the user before the script writes
anything, because that file is what every later layer reads.

## Steps

### 1. Locate the cadence skill's scripts

```bash
CAD=""
for p in \
    "${CLAUDE_PLUGIN_ROOT:-}/skills/cadence/scripts" \
    "$HOME/.claude/llm-orchestrator/skills/cadence/scripts" \
    "$(pwd)/.claude/skills/cadence/scripts"; do
  [[ -d "$p" ]] && { CAD="$p"; break; }
done
if [[ -z "$CAD" ]]; then
  found=$(find "$HOME/.claude/plugins" -name 'cadence-init.sh' -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1)
  [[ -n "$found" ]] && CAD="$(dirname "$found")"
fi
if [[ -z "$CAD" || ! -f "$CAD/cadence-init.sh" ]]; then
  echo "cadence scripts not found. Reinstall the plugin." >&2
  exit 1
fi
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

### 2. Propose a `cadence.json`

```bash
bash "$CAD/cadence-detect.sh" --root "$ROOT"
```

Show the user the whole proposal, not a summary — it is the contract the gate,
the check and the git layer all read. Then say in one line what it detected and
ask them to confirm or correct. Before writing the configuration, confirm:

- `workflow` is `proportional`. The init refuses any other value, or none.
- `runner.test_cmd`, `prod_globs` and `test_globs` match where this project's
  tests, production code and test files actually live. A `profile` of `unknown`
  means no test command was found: ask for the real command now rather than
  inventing one. If the user chooses to continue without one, say plainly that
  verification will stay pending until it is added, and that adding it later is
  a change to a protected file and so needs a numbered ruling.
- `typecheck_cmd` is right, or intentionally empty.

### 3. Write the confirmed JSON to a temp file

Only after the user confirms. Write exactly what they agreed to:

```bash
CFG=$(mktemp)
cat > "$CFG" <<'JSON'
<the confirmed cadence.json, verbatim>
JSON
```

### 4. Run the init

```bash
bash "$CAD/cadence-init.sh" --root "$ROOT" --config "$CFG"
```

Add `--adopt` when the user says this project already has its own laws (it
changes the report's wording and drops the placeholder reminder; nothing is
overwritten either way). Add `--dry-run` when they asked to see the plan first —
then stop and show them the plan.

The script writes, in this order: `LAWS.md` and its two companions →
`AGENTS.md` → `CLAUDE.md` → `.claude/settings.json` → `.githooks/` →
`docs/llm-orchestrator/cadence.json` last → the lock. It never overwrites: every
file the project already has comes back as `kept`, except `.claude/settings.json`,
which comes back `merged`. A marked `ORCH:LAWS` section that is not the current
block is refused; it changes only by a ruling.

### 5. Report

Open with `Changed:` and print the script's report once, verbatim — it names
`created` / `kept` / `merged` / `refused` per path, then the lock line and the
verdict. Under `Next:` relay the script's own numbered recipe in the order it
printed it, including the one line the script deliberately does not run for the
user:

```bash
git config core.hooksPath .githooks
```

Report the lock line separately, then end with an honest completion line: the
rulebook, the re-lock and the hook routing are still the user's to do, so end
with `Verification: PENDING — rulebook completion, re-locking and hook
activation remain`. A Git policy verdict is not test execution, so never write
PASS here.

The recipe the script prints is ordered, and the order is load-bearing: fill in
the `<PLACEHOLDER>`s, re-lock in the user's own terminal with the line the
script prints (the fill changed the laws after this run's manifest, and `--lock`
rewrites an existing lock only when a terminal is attached), route the clone's
hooks, then make the arming commit.

Then help the user write the laws. Point them at the filled-in example beside
the template, `skills/cadence/references/laws-example.md`, and offer to draft
wording for each placeholder in the conversation: the project's purpose, its
promises, the harm ranking, standing orders and hub files. Ask what is true for
this project rather than inventing it. The user pastes what they approve into
`LAWS.md`; you never write to that file yourself. Its last step is the CI one: run
`.githooks/orch-cadence-check.sh --audit HEAD` in the project's pipeline, which
is the layer that still speaks when a clone's hooks were never routed. Relay
the recipe as printed — a commit made before the re-lock meets the hook's
refusal. The recipe describes THIS run, not the project's state: after an
interrupted first run it starts from what this run created, so check the
placeholders and the re-lock yourself even when the recipe does not list them.

## Constraints

- Re-running this on an already-initialized project is a no-op while its
  `ORCH:LAWS` section still matches the current block,
  and a refusal once that section has drifted;
  either way nothing changes, for two separate reasons.
  First, the script itself keeps every file the project already has, and
  reports the lock as already armed.
  Second, the native deny rules refuse edits to the config paths (`LAWS.md`,
  `cadence.json`, `LOCK.sha256`, `.claude/settings.json`, `.githooks/**`) —
  present from the moment those rules are merged into `.claude/settings.json`.
  A protected file changes after that only by a ruling (`cadence-ruling.sh`).
- In an armed project whose hooks, marked block or deny rules are older than
  this plugin's, the script writes no protected file. It writes an upgrade
  ruling patch outside the project and prints the one `cadence-ruling.sh`
  command that applies it. Relay the patch path and the command; the user runs
  it in their own terminal. Never run it yourself.
- Never run `git config` for the user: routing a repo's hooks is their decision,
  so the one-liner is printed, not executed.
- Never fill in `LAWS.md`'s placeholders yourself, and never edit a `LAWS.md`
  the project already had — the laws are the user's, and `--adopt` exists so you
  do not have to touch them. Drafting wording in the conversation for the user
  to paste is fine; writing the file is not.
- If the script refuses (an unclosed code fence in `AGENTS.md`, no python3 with
  a settings file to merge, a config that does not parse), relay the refusal and
  stop. It is a preflight: nothing was written.
- The `cadence` skill carries what to do once the project is armed.
