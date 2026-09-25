# Codex

LLM Orchestrator is built for Claude Code. If you use Codex, you can install a
smaller part of it: the cadence skill and three small hooks. This page says
what you get, how to install it, and what it never does.

## What you get

- **The cadence skill.** It tells the assistant how much checking a change
  needs. A small change takes a quick path. A risky change gets independent
  review and real tests before it is called done. It is the same skill Claude
  Code uses.
- **The shared instructions** in `~/.codex/AGENTS.md`, so every Codex session
  knows to read a project's rulebook before changing code.
- **Three hooks.**
  1. *The file guard.* In a project that has cadence turned on, it stops the
     assistant from editing the rulebook, the config and the lock. Claude Code
     has built-in deny rules for this. Codex can make single paths read-only
     only through a permission profile in `~/.codex/config.toml`, which this
     setup does not write, so this hook fills that gap.
  2. *The completion check.* When a reply ends with `Verification: PASS`, it
     looks at the session log Codex already keeps and asks one question: did a
     test command actually run and pass in this turn? If not, it sends the
     assistant back once to run the check or change PASS to PENDING. You never
     see a message from it.
  3. *Scratch cleanup.* Removes temporary files left behind by finished tasks.

Everything else, such as planning, brainstorming, the reviewers and the merge
queue, stays in Claude Code.

## Install

1. Clone this repository into a folder you will keep, and add it to Codex as
   a plugin. The plugin installs the cadence skill and the three hooks.

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

3. Open a new Codex session and run `/hooks`. Review the three hooks and trust
   them. Codex only runs a hook you have trusted, and neither command can do
   that step for you.

What each step writes:

- `codex plugin add` copies the plugin into
  `~/.codex/plugins/cache/llm-orchestrator/` and records the marketplace and
  the plugin in `~/.codex/config.toml`. Codex runs the skill and the hooks
  from that copy.
- `install.sh --codex` adds the instructions block to `~/.codex/AGENTS.md`,
  after what is already there. It never touches `config.toml`. If something
  is in the way, such as a second pair of markers or a folder it cannot
  write, it stops and names the problem before writing anything.

## Update

```sh
cd llm-orchestrator
git pull --ff-only
codex plugin add llm-orchestrator@llm-orchestrator
./scripts/install.sh --codex
```

Codex runs the plugin from its own copy, and `git pull` does not change that
copy. Running `codex plugin add` again refreshes it. Then check `/hooks` in a
new session: a hook whose definition changed needs your trust again.

### Upgrading from an older install

Earlier releases of `install.sh --codex` copied the skill to
`~/.agents/skills/cadence` and added the hooks to `~/.codex/hooks.json`. With
the plugin installed as well, Codex would run each hook twice and list the
skill twice. Once the plugin is installed, `install.sh --codex` removes both.
Until then it removes nothing, so the old hooks keep working, and it says to
add the plugin first and run it again.

- From `~/.codex/hooks.json` it removes only the entries that run this
  plugin's hook scripts from this checkout, the plugin's cache or another
  llm-orchestrator checkout, including the ones v0.8 and v0.9 left behind.
  Your own entries stay, even a script of yours with the same name. The file
  as it was is kept as a backup beside it (`hooks.json.bak`, or a numbered
  `hooks.json.bak.1` if that name is taken), and the run prints its path.
- From `~/.agents/skills/cadence` it removes only the files this plugin
  ships, and only when the installer's `.orch-installed` marker is there. Any
  file you added is kept and named. A `cadence` skill without the marker is
  yours, and the installer leaves it in place and says so.

`./scripts/install.sh --check` shows whether anything from an older install
is left.

## Trust

Codex asks whether to trust each project and saves the answer in
`~/.codex/config.toml`. Checked against Codex 0.157.0:

- In a project marked untrusted, Codex does not read the project's
  `AGENTS.md` (since 0.150.0). It still reads `~/.codex/AGENTS.md`, so the
  cadence block still applies, but the project's own rules do not.
- A project's own `.codex/hooks.json` loads only when the project is trusted.
  The plugin's hooks are not in a project, so project trust does not affect
  them.
- A hook runs only after you trust it in `/hooks`. Trust is saved against a
  hash of the hook's definition: its event, matcher, command and timeout.
  Changing any of those asks for trust again. Editing the script a hook runs,
  or a new plugin version, does not.
- If `~/.codex/AGENTS.override.md` exists, Codex reads it instead of
  `~/.codex/AGENTS.md`, and the cadence block is not read at all. Copy the
  block into the override file, or remove the override.

## Claude Code import

Codex looks for `.codex-plugin/plugin.json` before `.claude-plugin/plugin.json`,
so the plugin install reads this repository's Codex manifest. That manifest
loads the cadence skill and the three hooks, and none of the Claude Code hooks
or skills. Codex `/import` also copies Claude Code plugins, and an imported
copy of this plugin reads the Codex manifest too.

One route still brings the Claude Code hooks over. A `--copy` install wires
them into a project's `.claude/settings.json`, and Codex offers to move hooks
found there into the project's `.codex/hooks.json`. Do not accept that for
this plugin's hooks, such as `session-start.sh` or `orch-verify-gate.sh`: they
are written for Claude Code's transcript and tools, not Codex's.

## Turn a project on

Cadence is per project. Open the project in Codex and ask the assistant to
enable cadence using the scripts in the cadence skill's `scripts/` folder. It
proposes the config and drafts the rulebook text for you to approve. The steps
are the same as in Claude Code: see
[Enable cadence in a project](install.md#enable-cadence-in-a-project).

## How the two checks behave

**The file guard** runs before every shell command and every patch. In a
project with cadence on, a command or patch that names a locked file is refused
unless it is one plain read, such as `cat docs/llm-orchestrator/LAWS.md` on its
own line. The refusal goes to the assistant with the way out. In every other
project it does nothing. It has no off switch. The only way past it is to start
the session unlocked, as described under
[Escape hatches](install.md#escape-hatches-for-the-hard-guards).

**The completion check** runs when the assistant stops. It reads only the
records Codex writes when a command finishes, with the exact command and exit
code. Nothing the assistant wrote or printed counts. If the reply says PASS and no
test command finished with exit code 0 in this turn, the assistant is sent back
once with a short note. On that second stop the check stays quiet, so it can
never loop. It never blocks you, never hashes files and never prints for you.

Turn it off with `ORCH_DISABLED_HOOKS=codex-verify-gate` or
`ORCH_HOOK_PROFILE=minimal`.

## Limits, stated plainly

- The check recognises test commands from lists shared with Claude Code:
  `npm test`, `pytest`, `.ve/bin/pytest`, `pnpm --filter web vitest run`,
  `aws-vault exec profile -- pytest`, `bash tests/...` and the like. A
  command that starts with the project's `runner.test_cmd` from
  `docs/llm-orchestrator/cadence.json` also counts. A check hidden in a
  background job, behind `|| true` or after `false &&` slips past on purpose. It
  catches careless claims, not deliberate disguises.
- It reads Codex's session log, which Codex says is not a stable format. If a
  future Codex stops writing command records, every PASS will be sent back once
  until the check is updated. That is the safe direction.
- A thread whose session log says `"history_mode": "legacy"` records no
  command that a code-mode `exec` script runs (seen in Codex Desktop
  0.154.0-alpha threads). In such a turn the check says nothing, so a false
  PASS there is not caught. Commands run directly through `exec_command` are
  still read in every thread.
- It was run over every session log on the machine it was built on (348 files)
  without a crash, but the test suite drives it with recorded log shapes, not a
  live session. One Codex turn that ends in PASS with no check is enough to see
  it work.

## Optional: a Claude reviewer from Codex

On Full work, one of the two independent reviews can come from Claude through
your existing Claude login. See [codex-provider.md](codex-provider.md).

## Tests

```sh
bash tests/test-codex-verify-gate.sh   # the completion check on log fixtures
bash tests/test-codex-adapter.sh       # the file guard
bash tests/test-install-global.sh      # the installer under a temporary HOME;
                                       # with CODEX_BIN set, a real plugin install
                                       # and Codex's own list of hooks and skills
python3 tests/test-claude-provider.py  # the optional Claude reviewer, with a fake CLI
```
