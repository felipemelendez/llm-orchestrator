# Codex

The plugin's home is Claude Code. Codex gets the same cadence with the same
two checks, installed by one command, and nothing else: no per-command
evidence tracker, no verification runner, no receipts for shell commands.

## Install

From a checkout of this repository that you intend to keep:

```sh
./scripts/install.sh --codex
```

It does three things, all under your home directory (a path reached through a
link is judged by where it really is, the skill directory included):

1. Copies the cadence skill to `~/.agents/skills/cadence`. It is a copy, not a
   link: re-run the installer after updating the plugin.
2. Renders the shared cadence block into `~/.codex/AGENTS.md`, the same block
   `--global` puts in `~/.claude/CLAUDE.md`.
3. Merges the hooks into `~/.codex/hooks.json`: the file guard (on `PreToolUse`,
   registered once for `Bash` and once for `apply_patch`), the completion
   check and the task-scratch cleanup (both on `Stop`). Your own entries in
   that file survive (ours are recognised by the script they run, by its name
   and its `scripts/hooks` directory, never by a word elsewhere on the line;
   your own `my-hooks/codex-verify-gate.sh` is yours, and so is a `bash -c`
   wrapper of yours that names our script as an argument), a second run replaces
   ours instead of adding beside them, and the file as it was before the
   first run is kept as `hooks.json.bak`. Entries an earlier release
   registered for files that no longer ship are removed. Every refusal comes
   before the first write: a file of your own inside the skill copy (a link,
   a file where a shipped directory should be, a marker below the root, an
   empty directory) is one of them, named; so is a directory this user cannot enter, and so are
   two destinations that turn out to be one file, or one inside the skill
   copy. The old copy is moved aside before the new one is written, so the
   copy is always whole; if the old one then cannot be deleted (an immutable
   file, say), it is left beside the copy, named, for you to remove.

Then open a fresh Codex session and run `/hooks` to review and trust those
definitions. Codex runs a hook only after you have trusted its exact text;
the installer cannot do that for you. `config.toml` is never touched.

## The two checks

**The file guard** (`scripts/hooks/codex-cadence-adapter.sh`, on `PreToolUse`
for `Bash` and `apply_patch`). Claude Code refuses edits to the locked cadence
files through its own deny rules; Codex has no such rule, so this hook is that
one layer. A shell command or a patch that names a locked file and is not one
plain read is refused, and the refusal, with the way out, goes back to the
agent as the reason its command was refused. It reads raw text,
so a locked file inside a pipeline or a multi-line command is refused even as
a read: read it as `cat <file>` on its own line. It is inert in a project with
no enabled `cadence.json`.

**The completion check** (`scripts/hooks/codex-verify-gate.sh`, on `Stop`).
The Codex twin of `orch-verify-gate.sh`. When a reply ends with
`Verification: PASS`, it reads the session log Codex already keeps and asks
one question: did a command matching the shared check pattern run in this turn
and finish with exit code 0? It reads only the record Codex writes for every
command it runs, with the exact command and exit code; nothing the agent
wrote or printed is read. The pattern is the one both harnesses share
(`ORCH_SIG_VERIFY_CMD` in `scripts/lib/orch-signals.sh`), the label vocabulary
is the same (`PASS`, `PENDING`, `BLOCKED`, `NOT APPLICABLE`), and the note is
the same text. It never hashes files, never watches commands as they run, and
never exits non-zero.

Where the note goes is the one difference from Claude Code. Claude Code can
hand the model a note quietly. Codex's Stop hook has two outputs: a warning in
your UI, or a continuation that sends the agent back to work with a reason.
An agent's missing check is the agent's problem, so the note goes to the agent
as a single continuation and the check never addresses you. The agent then
runs the check, or changes PASS to PENDING. On that continuation the hook is
quiet, and the installer keeps one registration of it, so it fires at most
once per turn. Whether Codex's UI also shows the
continuation prompt it created is Codex's choice and not documented; the
hook itself never prints a message for you.

## What it reads, and what that rests on

`ORCH_DISABLED_HOOKS=codex-verify-gate` and `ORCH_HOOK_PROFILE=minimal` turn
the completion check off. (The file guard has no such switch: a guard that
can be talked off is not a guard; the session unlock is its one way out.)

The hook reads `transcript_path` from the Stop payload, which is the session's
rollout file under `~/.codex/sessions/`. It reads one kind of entry: the
record Codex writes when a command finishes (`item_completed` /
`CommandExecution`, with the argv, the exit code and the turn). Codex has
written those since August 2026; every command in every such log on this
machine has one. The payload's `turn_id` selects this turn's records. Codex's
docs say the transcript format is not a stable interface: if a future build
stops writing these records, every PASS will be sent back once until the
check is updated, which is the safe direction.

The command's text is read the plain way: split at `;`, `&`, `|` and
newlines, matched against the pattern. `npm test &`, a check named inside a
heredoc or a quoted string, and `npm test || true` get past it, on purpose:
those are disguises, and the check catches the careless false claim, not the
deliberate one. The spec lists them and says why no parsing rule will be
added for them.

It has not been exercised against a live Codex session in this repository's
tests; the suites drive the hook with recorded log shapes, and it was run
over every rollout on this machine (348 files, no crash, nothing printed for
the person). After installing
and trusting, one Codex turn that ends in `Verification: PASS` without a check
is enough to see it work.

## Optional: a Claude reviewer from Codex

For one of the two independent reviews on Full work you can dispatch Claude
from a Codex session through your existing Claude login. That runner is
`scripts/providers/claude-review.py`; see [codex-provider.md](codex-provider.md).

## Tests

```sh
bash tests/test-codex-verify-gate.sh   # the completion check on rollout fixtures
bash tests/test-codex-adapter.sh       # the file guard
bash tests/test-install-global.sh      # --codex under a temporary HOME
python3 tests/test-claude-provider.py  # the optional Claude reviewer, with a fake CLI
```
