# Skills guide

How the plugin's skills are shaped, and how to write a new one. For the
step-by-step method, including testing a skill on a fresh agent, see the
`writing-skills` skill.

## Shape

A skill is one folder with one file, `skills/<name>/SKILL.md`. Supporting
files (references, scripts) can sit next to it.

The frontmatter (the block between `---` lines at the top) has two keys:

- `name` — lowercase with hyphens, the same as the folder name.
- `description` — when to use the skill, starting with "Use when". Claude Code
  reads it to decide whether to load the skill, so describe the trigger, not
  the steps. A description that summarises the steps lets the model skip the
  body.

```yaml
---
name: writing-plans
description: Use when a spec is approved and implementation has not started, to write a checklist plan.
---
```

Good: "Use when a diff is ready for review, before merge or before claiming a
feature is done." Bad: "Reviews code by checking files in order and scoring
issues."

## Body

- There are no required sections; use the headings the content needs. Most
  skills end with an "Output shape" section showing the reply the agent should
  give, in the [Concise Agent Protocol](../concise-agent-protocol.md).
- Write only what a capable model would get wrong without it. Keep a short
  reason next to a rule only when the agent will be tempted to break it.
- Number steps only when the order matters.
- Plain voice: no runs of all-caps words, no walls of "MUST", no
  rationalization tables, no diagrams.
- Aim for about 150 lines; the hard limit is 250.

## Adding a skill

```sh
mkdir skills/<name>
cp templates/skill.md skills/<name>/SKILL.md
$EDITOR skills/<name>/SKILL.md
./tests/validate-skills.sh
```

The validator checks that the folder matches `name`, the description starts
with "Use when", the file is at most 250 lines, there are no four or more
all-caps words in a row outside code blocks, and existing skills stay under
their word ceilings.

Do not add a skill when an existing one covers the behaviour, or when it is
really a single action (make it a [command](commands-guide.md)).
