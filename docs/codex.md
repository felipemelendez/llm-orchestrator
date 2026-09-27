# Codex

LLM Orchestrator is built for Claude Code. On Codex you can install a smaller
part of it. This page says what you get, how to install and update it, and
what it does not do.

## What you get

- **The cadence skill.** It tells the assistant how much checking a change
  needs, in projects that turn the cadence on. It is the same skill Claude
  Code uses.
- **The review skill** (`requesting-code-review`), which runs the same review
  script as on Claude Code. See [Reviews from Codex](codex-provider.md).
- **The shared instructions** in `~/.codex/AGENTS.md`, so every Codex session
  knows to read a project's rulebook before changing code.
- **Three hooks:**
  1. *The file guard.* In a project with the cadence on, it refuses a command
     or patch that would change the rulebook, the config or the lock.
  2. *The completion check.* When a reply says `Verification: PASS` and no test
     ran and passed in that turn, it sends the assistant back once to run the
     check or change PASS to PENDING.
  3. *Scratch cleanup.* It removes temporary files left by finished tasks.

None of the hooks prints a message for you. Planning, brainstorming, the other
skills and hooks, and the merge queue stay in Claude Code.

## Install

1. Clone this repository into a folder you will keep, and add it to Codex as a
   plugin. This installs the two skills and the three hooks.

   ```sh
   git clone https://github.com/felipemelendez/llm-orchestrator.git
   cd llm-orchestrator
   codex plugin marketplace add "$PWD"
   codex plugin add llm-orchestrator@llm-orchestrator
   ```

2. Add the instructions block to `~/.codex/AGENTS.md`. The plugin cannot do
   this part.

   ```sh
   ./scripts/install.sh --codex
   ```

3. Open a new Codex session, run `/hooks`, and trust the three hooks. Codex
   runs only hooks you have trusted, and no command can do this step for you.

What each step writes:

- `codex plugin add` copies the plugin into Codex's plugin cache under
  `~/.codex/plugins/cache/` and records it in `~/.codex/config.toml`. Codex
  runs the skills and hooks from that copy.
- `install.sh --codex` adds the instructions block to the end of
  `~/.codex/AGENTS.md`. It never touches `config.toml`. If something is in the
  way, such as a second pair of markers or a folder it cannot write, it stops
  and names the problem before writing anything.

## Turn a project on

The cadence is per project. Open the project in Codex and ask the assistant to
enable the cadence using the scripts in the cadence skill's `scripts/` folder.
The steps are the same as in Claude Code:
[Enable cadence in a project](install.md#enable-cadence-in-a-project).

## Update

```sh
cd llm-orchestrator
git pull --ff-only
codex plugin add llm-orchestrator@llm-orchestrator
./scripts/install.sh --codex
```

`git pull` does not change the copy Codex runs; `codex plugin add` refreshes
it. Then check `/hooks` in a new session: a hook whose definition changed needs
your trust again.

### Upgrading from an older install

Releases before 0.12.0 had `install.sh --codex` copy the skill to
`~/.agents/skills/cadence` and add the hooks to `~/.codex/hooks.json`. With the
plugin installed too, Codex would run each hook twice. Once the plugin is
installed, `install.sh --codex` removes the old copies. Until then it removes
nothing, so the old hooks keep working, and it tells you to add the plugin
first.

- From `~/.codex/hooks.json` it removes only entries that run this plugin's
  hook scripts. Your own entries stay. The file as it was is kept beside it as
  `hooks.json.bak` (or a numbered `.bak.1`), and the run prints the path.
- From `~/.agents/skills/cadence` it removes only files this plugin ships, and
  only when the old installer's `.orch-installed` marker is there. Files you
  added are kept and named. A `cadence` skill without the marker is left alone.

`./scripts/install.sh --check` shows whether anything from an older install is
left.

## Trust and what Codex reads

Codex asks whether to trust each project and saves the answer in
`~/.codex/config.toml`. As of Codex 0.157.0:

- In an untrusted project, Codex does not read the project's `AGENTS.md`. It
  still reads `~/.codex/AGENTS.md`, so the cadence block applies, but the
  project's own rules do not.
- A project's own `.codex/hooks.json` loads only in a trusted project. The
  plugin's hooks are not in a project, so project trust does not affect them.
- A hook runs only after you trust it in `/hooks`. Trust is tied to the hook's
  event, matcher, command and timeout; changing any of them asks again.
  Editing the script a hook runs, or a new plugin version, does not.
- If `~/.codex/AGENTS.override.md` exists, Codex reads it instead of
  `~/.codex/AGENTS.md`, and the cadence block is not read. Copy the block into
  the override file, or remove the override.

Codex reads this repository's `.codex-plugin/plugin.json` before the Claude
Code manifest, so installing it (or importing it with Codex `/import`) loads
only the two skills and three hooks above. One route still brings Claude Code
hooks over: a `--copy` install wires them into a project's
`.claude/settings.json`, and Codex may offer to move them into
`.codex/hooks.json`. Decline that for this plugin's hooks; they are written
for Claude Code.

## How the two checks behave

**The file guard** runs before every shell command and patch. In a project
with the cadence on, a command or patch that names a locked file is refused
unless it is one plain read on its own line, such as
`cat docs/llm-orchestrator/LAWS.md`. The refusal tells the assistant how to
read the file and that a change is a ruling. It has no off switch: a locked
file changes only by [a ruling](install.md#changing-the-rules) you apply in
your own terminal. In other projects it does nothing.

**The completion check** runs when the assistant stops. It reads only the
records Codex writes when a command finishes, with the exact command and exit
code; nothing the assistant wrote counts. If the reply says PASS and no test
command finished with exit code 0 in that turn, the assistant is sent back once
with a short note, which also asks it to repeat its full answer, because that
reply becomes the final one. It stays quiet on the second stop, so it never
loops.

Turn it off with `ORCH_DISABLED_HOOKS=codex-verify-gate` or
`ORCH_HOOK_PROFILE=minimal`.

## Limits

- It recognises the same test commands as the Claude Code check: `npm test`,
  `pytest`, `.venv/bin/pytest`, `pnpm --filter web vitest run`,
  `aws-vault exec profile -- pytest`, `bash tests/...` and the like, plus any
  command that starts with the project's `runner.test_cmd`. A check in a
  background job, behind `|| true` or after `false &&` gets past it. It catches
  careless claims, not deliberate disguises.
- It reads Codex's session log, which Codex says is not a stable format. If a
  future Codex stops writing command records, every PASS is sent back once
  until the check is updated.
- In a thread whose log says `"history_mode": "legacy"`, commands run inside a
  code-mode `exec` script leave no record, so the check says nothing for that
  turn. Commands run directly are still read.

## Tests

```sh
bash tests/test-codex-verify-gate.sh   # the completion check, on recorded logs
bash tests/test-codex-adapter.sh       # the file guard
bash tests/test-install-global.sh      # the installer, under a temporary HOME
python3 tests/test-review.py           # the review script, with fake claude and codex
```
