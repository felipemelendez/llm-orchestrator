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

1. Clone this repository into a folder you will keep. The hooks point at
   scripts inside it.

   ```sh
   git clone https://github.com/felipemelendez/llm-orchestrator.git
   cd llm-orchestrator
   ./scripts/install.sh --codex
   ```

2. Open a new Codex session and run `/hooks`. Review the three hooks and trust
   them. Codex only runs a hook you have trusted, and the installer cannot do
   that step for you.

That is all. The installer never touches `config.toml`. Codex itself saves
project trust and hook trust there.

What it writes, all under your home folder:

- `~/.agents/skills/cadence`: a copy of the skill.
- `~/.codex/AGENTS.md`: the instructions block, added to what is already there.
- `~/.codex/hooks.json`: the three hooks, added next to your own entries. The
  file as it was before is kept as `hooks.json.bak`.

Running the installer again replaces its own entries and leaves yours alone.
If something is in the way, such as a file of yours inside the skill folder or
a folder it cannot write, it stops and names the problem before writing
anything.

## Update

```sh
cd llm-orchestrator
git pull --ff-only
./scripts/install.sh --codex
```

The skill is a copy, so it only changes when you rerun the installer. Then
check `/hooks` in a new session: a hook whose definition changed needs your
trust again.

If you installed the Codex layer from v0.8 or v0.9, this run also removes old
hook entries that pointed at deleted files and made every command fail.

## Trust

Codex asks whether to trust each project and saves the answer in
`~/.codex/config.toml`. Checked against Codex 0.157.0:

- In a project marked untrusted, Codex does not read the project's
  `AGENTS.md` (since 0.150.0). It still reads `~/.codex/AGENTS.md`, so the
  cadence block still applies, but the project's own rules do not.
- A project's own `.codex/hooks.json` loads only when the project is trusted.
  The installer's hooks are in `~/.codex/hooks.json`, so project trust does
  not affect them.
- A hook runs only after you trust it in `/hooks`. Trust is saved against a
  hash of the hook's definition: its event, matcher, command and timeout.
  Changing any of those asks for trust again. Editing the script a hook runs,
  or a new plugin version, does not.
- If `~/.codex/AGENTS.override.md` exists, Codex reads it instead of
  `~/.codex/AGENTS.md`, and the cadence block is not read at all. Copy the
  block into the override file, or remove the override.

## Codex plugin install and Claude Code import

Codex can add this repository as a plugin (`codex plugin marketplace add`,
then `codex plugin add llm-orchestrator@llm-orchestrator`). Codex looks for
`.codex-plugin/plugin.json` before `.claude-plugin/plugin.json`, so it reads
this repository's Codex manifest. That manifest loads the cadence skill and
the same three hooks, and none of the Claude Code hooks or skills. Without it,
Codex would load the Claude Code manifest and all of `hooks/hooks.json`.

The installer above is the supported install. The plugin does not add the
instructions block to `~/.codex/AGENTS.md`. Use one or the other for the skill
and hooks, not both: with both, each hook is registered twice, so it runs
twice, and the skill is listed twice.

To update a plugin install, run `codex plugin add llm-orchestrator@llm-orchestrator`
again. Codex runs the plugin from its own cached copy, and neither `git pull`
nor `codex plugin marketplace upgrade` refreshes that copy.

Codex `/import` also copies Claude Code plugins. An imported copy of this
plugin reads the Codex manifest too: the cadence skill and the same three
hooks.

One route still brings the Claude Code hooks over. A `--copy` install wires
them into a project's `.claude/settings.json`, and Codex offers to move hooks
found there into the project's `.codex/hooks.json`. Do not accept that for
this plugin's hooks, such as `session-start.sh` or `orch-verify-gate.sh`: they
are written for Claude Code's transcript and tools, not Codex's.

## Turn a project on

Cadence is per project. Open the project in Codex and ask the assistant to
enable cadence using the scripts in `~/.agents/skills/cadence/scripts/`. It
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

**The completion check** runs when the assistant stops. It reads only the log
Codex writes for every command it runs, with the exact command and exit code.
Nothing the assistant wrote or printed counts. If the reply says PASS and no
test command finished with exit code 0 in this turn, the assistant is sent back
once with a short note. On that second stop the check stays quiet, so it can
never loop. It never blocks you, never hashes files and never prints for you.

Turn it off with `ORCH_DISABLED_HOOKS=codex-verify-gate` or
`ORCH_HOOK_PROFILE=minimal`.

## Limits, stated plainly

- The check recognises test commands by a shared pattern: `npm test`,
  `pytest`, `bash tests/...` and the like. A check hidden in a background job,
  a heredoc, a quoted string or behind `|| true` slips past on purpose. It
  catches careless claims, not deliberate disguises.
- It reads Codex's session log, which Codex says is not a stable format. If a
  future Codex stops writing command records, every PASS will be sent back once
  until the check is updated. That is the safe direction.
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
bash tests/test-install-global.sh      # the installer under a temporary HOME
python3 tests/test-claude-provider.py  # the optional Claude reviewer, with a fake CLI
```
