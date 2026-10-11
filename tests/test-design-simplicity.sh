#!/usr/bin/env bash
# Every reviewer brief carries the design-simplicity check.
#
# The rule (Felipe, 2026-10-11): every review, at every path and on both
# harnesses, also asks "Is this the simplest correct version?" and reports a
# design finding with its simpler alternative, never as a style note. The
# question and the finding definition are written once, in
# skills/requesting-code-review/references/design-simplicity.md; every brief
# names that file and carries the question itself, so a reader who never opens
# the file still asks it.
#
# This suite collects every brief the plugin ships as text — the review skill
# and its prover and refuter briefs, the cadence paths and the rulebook
# templates, the spec and plan reviewer prompts and the agent that reads them,
# the dispatch envelopes that tell implementers what reviewers check, the
# installed instruction blocks and this repository's own AGENTS.md — and fails
# when one lacks the question or the file's name. The briefs the review script
# renders at run time (the reviewer instruction, the prover and the refuter
# prompts) are checked by tests/test-review.py with fake CLIs; the script's
# kind and its alternative are pinned here as text.
#
# The list below is hand-kept, so a discovery pass adds every file under
# skills/, agents/ and templates/ whose name says "review": a new reviewer
# prompt is checked without anyone editing this file. The check is proven to
# fire on a seeded brief before the tree is read.
#
# Usage: bash tests/test-design-simplicity.sh
# Exit codes: 0 = all checks passed, 1 = at least one failed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET_REL="skills/requesting-code-review/references/design-simplicity.md"
SNIPPET="$ROOT/$SNIPPET_REL"
QUESTION='Is this the simplest correct version?'

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }

# A brief carries the check when it asks the question in its own words-for-words
# and names the shared file the finding definition lives in.
carries() { has "$1" "$QUESTION" && has "$1" "design-simplicity.md"; }

BRIEFS="
skills/requesting-code-review/SKILL.md
skills/requesting-code-review/references/prover.md
skills/requesting-code-review/references/refuter.md
skills/receiving-code-review/SKILL.md
skills/cadence/SKILL.md
skills/cadence/CADENCE.md
skills/cadence/references/laws.md
skills/cadence/references/laws-example.md
skills/cadence/references/global-block.md
skills/dispatching-subagents/SKILL.md
skills/dispatching-parallel-agents/SKILL.md
templates/cadence-global-block.md
templates/scaffold-AGENTS.md
templates/scaffold-CLAUDE.md
templates/implementer-prompt.md
templates/dispatch-prompt.md
AGENTS.md
"

printf '\n== The check fires on a brief without the question (positive control) ==\n'
CONTROL="$(mktemp "${TMPDIR:-/tmp}/design-control.XXXXXX")"
printf 'You review a change. Report every defect.\n' > "$CONTROL"
if carries "$CONTROL"; then fail "positive control" "a brief with no question passed the check"
else ok "a brief without the question fails the check"; fi
printf '%s See design-simplicity.md.\n' "$QUESTION" >> "$CONTROL"
if carries "$CONTROL"; then ok "a brief with the question and the file name passes the check"
else fail "positive control" "a brief with both still fails the check"; fi
rm -f "$CONTROL"

printf '\n== The shared snippet ==\n'
if [ -f "$SNIPPET" ]; then
  ok "$SNIPPET_REL exists"
  has "$SNIPPET" "$QUESTION" && ok "it asks: $QUESTION" || fail "the question" "the snippet does not ask it"
  for phrase in "unnecessary abstraction or indirection" \
                "extra state, flags or configuration" \
                "duplicated mechanisms" \
                "new helper" \
                "more code or more moving parts" \
                "coupling or lifecycle complexity" \
                "simpler alternative" \
                "Severity follows harm" \
                "stays correct" \
                "subtly wrong"; do
    has "$SNIPPET" "$phrase" && ok "it defines: $phrase" || fail "the finding definition" "the snippet lacks \"$phrase\""
  done
else
  fail "$SNIPPET_REL" "missing; every brief is meant to reference this one file"
fi

printf '\n== Every brief asks the question and names the file ==\n'
for rel in $BRIEFS; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then fail "$rel" "missing"; continue; fi
  if carries "$f"; then ok "$rel"
  else fail "$rel" "lacks \"$QUESTION\" or the name design-simplicity.md"; fi
done

printf '\n== Discovered reviewer prompts (any file named *review* under skills/, agents/, templates/) ==\n'
FOUND=0
while IFS= read -r f; do
  FOUND=$((FOUND+1))
  rel="${f#"$ROOT"/}"
  if carries "$f"; then ok "$rel"
  else fail "$rel" "a reviewer prompt without \"$QUESTION\" or the name design-simplicity.md"; fi
done < <(find "$ROOT/skills" "$ROOT/agents" "$ROOT/templates" -type f -name '*review*' ! -name '*.json' | sort)
[ "$FOUND" -ge 3 ] && ok "$FOUND reviewer prompts discovered (spec reviewer agent, spec and plan prompts at least)" \
  || fail "discovery" "found $FOUND files named *review*; the spec reviewer agent and the spec and plan prompts should be there"

printf '\n== The review script carries the kind and its alternative ==\n'
SCRIPT="$ROOT/scripts/lib/orch-review.py"
SCHEMA="$ROOT/skills/requesting-code-review/references/prover-schema.json"
has "$SCRIPT" '"design-simplicity.md"' && ok "orch-review.py reads design-simplicity.md" \
  || fail "orch-review.py" "it never reads design-simplicity.md"
grep -qE '^KINDS = .*"design-simplicity"' "$SCRIPT" && ok "KINDS lists design-simplicity" \
  || fail "KINDS" "orch-review.py's KINDS has no design-simplicity"
has "$SCRIPT" "simpler_alternative" && ok "orch-review.py carries simpler_alternative" \
  || fail "simpler_alternative" "orch-review.py never reads it"
if python3 - "$SCHEMA" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1]))
item = schema["properties"]["results"]["items"]
ok = ("design-simplicity" in item["properties"]["kind"]["enum"]
      and "simpler_alternative" in item["required"]
      and "simpler_alternative" in item["properties"])
sys.exit(0 if ok else 1)
PY
then ok "prover-schema.json has the design-simplicity kind and a required simpler_alternative"
else fail "prover-schema.json" "missing the design-simplicity kind or the simpler_alternative field"; fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%d checks passed (design simplicity).\n' "$PASS"; exit 0
else
  printf '%d passed, %d failed.\n' "$PASS" "$FAIL"; exit 1
fi
