# The cadence

The cadence is an optional set of rules for one project. It matches the amount
of checking to the risk of a change: a small change takes a quick path, a risky
one gets independent review, and nothing is called done until the project's
tests ran. This page covers turning it on, changing its rules, and what
protects them.

Two words used below:

- **Ruling** — a numbered change you approve, written into the project's
  rulebook (`Ruling <N>`). The rules change only this way.
- **Locked** — once setup is finished, the rulebook and config are recorded in
  a lock file, and a change to them without a ruling is refused or reported.

## Enable cadence in a project

It takes about fifteen minutes and gives the project a config that says how to
run its tests, a rulebook, and a lock over both.

1. **Run the initializer.** In Claude Code, open the project and run
   `/llm-orchestrator:cadence-init`. In Codex, ask the assistant to enable the
   cadence using the scripts in the cadence skill's `scripts/` folder.
2. **Confirm the config.** The assistant shows a proposed
   `docs/llm-orchestrator/cadence.json`. Check that the test command is the one
   you use, and that the folders listed as production code and tests are right.
   If it found no test command, it says so; until you add one, the assistant
   reports verification as pending, not passed.
3. **Write the rulebook.** The initializer creates
   `docs/llm-orchestrator/LAWS.md` from a template with `<PLACEHOLDER>` slots:
   what the project is, what you promise its users, what counts as
   catastrophic, serious or mild, and your standing orders. A filled-in example
   ships as [`laws-example.md`](../skills/cadence/references/laws-example.md).
   The assistant can draft wording in the conversation; you decide what goes
   in, and it never edits the file itself.
4. **Finish setup.** The initializer prints these steps, with the exact
   commands, in this order:
   1. Fill in every placeholder in `LAWS.md`.
   2. In your own terminal, run the `--lock` command it printed. This records
      the finished rulebook and config in the lock.
   3. Run `git config core.hooksPath .githooks` once in each clone. The commit
      check works only after this.
   4. Commit the setup files. This first commit needs no ruling.
   5. If the project has CI, add [the CI step](#the-ci-step).

Your rulebook, config and test commands live in your project and survive
plugin updates.

## Changing the rules

These files are locked: `docs/llm-orchestrator/LAWS.md`, `cadence.json`,
`LOCK.sha256`, `.claude/settings.json`, `.githooks/commit-msg`,
`.githooks/orch-cadence-check.sh`, and the section of `CLAUDE.md` and
`AGENTS.md` between the `<!-- ORCH:LAWS:START -->` and
`<!-- ORCH:LAWS:END -->` markers. The rest of `CLAUDE.md` and `AGENTS.md` stays
yours to edit.

When the assistant thinks a rule should change, it explains why and gives you
the change as a patch file kept outside Git, with the command to apply it. If
you agree, run that command in your own terminal. It looks like this:

```sh
bash "$(find ~/.claude/plugins -name cadence-ruling.sh -path '*llm-orchestrator*' | tail -1)" \
  --root <your project> <patch-file> "<your wording>"
```

The command checks that the patch touches only locked files and adds the next
ruling to `LAWS.md`, asks you to type `ruling <N>`, then applies the patch,
re-records the lock, and commits `Ruling <N>: <your wording>`. If a step fails
or you interrupt it, it puts everything back. It refuses to run from inside an
assistant session; run it in your own terminal.

## The lock

### The lock's two layers

**Layer 1 — deny rules.** The initializer adds `Edit(...)` deny rules to
`.claude/settings.json` for `LAWS.md`, `cadence.json`, `LOCK.sha256`,
`.claude/settings.json` and `.githooks/`. Claude Code then refuses to edit
those files, through its file tools and through shell commands that write to
them, in every permission mode. How this was checked:
[cadence-evidence.md](cadence-evidence.md). On Codex, the plugin's file guard
does this job ([Codex](codex.md)).

With Claude Code's sandbox on, the same rules also cover any script the
assistant runs. Turn it on with `/sandbox` in a session, or
`"sandbox": {"enabled": true}` in `.claude/settings.json`. The plugin never
turns it on for you, because it changes how every command in the session
behaves.

**Layer 2 — the commit hook.** `.githooks/commit-msg` refuses a commit that
changes a locked file without a numbered ruling. It works only in clones where
`git config core.hooksPath .githooks` has been run.

Three more checks report a change rather than prevent it:

| Check | When | What it does |
|---|---|---|
| End-of-turn check | every turn | tells the assistant whether the lock still matches; blocks once per session only with `ORCH_STRICT_CADENCE_LOCK=1` |
| Session-start line | each session start, and after the conversation is compacted | repeats that check, so a change nobody watched is the first thing the next session reads |
| `orch-cadence-check.sh --audit` | in CI | the commit check, on a pushed commit |

### The CI step

Add this to the project's CI; it is the same line the initializer prints:

```
.githooks/orch-cadence-check.sh --audit HEAD
```

It fails when a locked file changed without a numbered ruling, and covers
clones whose git hooks were never turned on. In GitHub Actions, on a feature
branch:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- name: Fetch main
  if: github.ref != 'refs/heads/main'
  run: git fetch --no-tags origin main:refs/heads/main
- name: Cadence audit
  run: bash .githooks/orch-cadence-check.sh --audit HEAD
```

`fetch-depth: 0` gives the audit the parent commit to compare against. The
`main` fetch is needed on a feature branch; it is skipped on `main`, where git
refuses to fetch into the checked-out branch.

### What the lock cannot stop

The lock stops accidental edits and makes deliberate ones visible. A write the
deny rules miss, such as one by a script the assistant runs, still happens; it
is reported at the end of that turn and at the next session start, and a
commit of it is refused unless it also carries a numbered ruling.

It cannot stop an assistant set on faking a ruling. A script can rewrite
`LAWS.md` and `LOCK.sha256` together and commit with a `Ruling <N>` message,
which the commit hook accepts; and an assistant that runs the ruling command
inside a pseudo-terminal gets past its "own terminal" check. Either way the
commit shows in the history as a ruling you did not make.

The hooks find the project from the folder the session started in. A cadence
project edited from a session started elsewhere is covered only by the deny
rules and the git layer.
