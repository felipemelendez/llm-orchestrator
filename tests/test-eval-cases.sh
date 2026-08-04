#!/usr/bin/env bash
# Eval cases are graders, and a grader that grades wrongly does not fail loudly —
# it returns a confident wrong answer on a run that already cost real money. Two
# drafts of tdd-under-pressure shipped broken: one where the planted "bug" was not
# a bug (every check passed before the agent touched anything, so both arms scored
# 100%), and one with a check that could never pass. Both were caught by hand.
# This catches them for free, before any run.
#
# The load-bearing assertion is RED-BEFORE: run a case's setup in a scratch dir and
# require at least one of its checks to fail there. A case that is already green
# before the agent acts measures nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR="${ROOT}/tests/evals/cases"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
if ! command -v git >/dev/null 2>&1; then
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    echo "FAIL: git required (ORCH_REQUIRE_DEPS=1)"; exit 1
  fi
  echo "SKIP: git not found"; exit 0
fi
[[ -d "$CASE_DIR" ]] || { echo "FAIL: $CASE_DIR missing"; exit 1; }

echo "== eval cases =="

# --- structure ---------------------------------------------------------------------
struct="$(python3 - "$CASE_DIR" <<'PY'
import json, pathlib, re, sys
d = pathlib.Path(sys.argv[1])
seen, problems = {}, []
files = sorted(d.glob("*.json"))
if not files:
    problems.append("no case files found")
for f in files:
    try:
        c = json.loads(f.read_text())
    except Exception as e:
        problems.append(f"{f.name}: invalid JSON ({e})"); continue
    cid = c.get("id")
    if not cid:
        problems.append(f"{f.name}: no id"); continue
    if cid != f.stem:
        problems.append(f"{f.name}: id '{cid}' does not match filename")
    if cid in seen:
        problems.append(f"{f.name}: duplicate id '{cid}' (also {seen[cid]})")
    seen[cid] = f.name
    if not (c.get("prompt") or "").strip():
        problems.append(f"{cid}: empty prompt")
    exp = c.get("expect", {}) or {}
    for kind in ("must_match", "must_not_match"):
        for pat in exp.get(kind, []):
            try:
                re.compile(pat)
            except re.error as e:
                problems.append(f"{cid}: {kind} pattern does not compile: {pat!r} ({e})")
    # A case with neither a text assertion nor an execution check grades nothing,
    # and the runner scores an empty check list as a fail on every row.
    if not any(exp.get(k) for k in ("must_match", "must_not_match", "must_open_with")) \
       and not c.get("check"):
        problems.append(f"{cid}: no assertions at all — the case cannot grade anything")
    if not (c.get("why") or "").strip():
        problems.append(f"{cid}: no 'why' — a case nobody can justify is a case nobody dares delete")
print(json.dumps({"n": len(files), "problems": problems}))
PY
)"
nprob="$(printf '%s' "$struct" | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['problems']))")"
ncase="$(printf '%s' "$struct" | python3 -c "import json,sys;print(json.load(sys.stdin)['n'])")"
if [[ "$nprob" == "0" ]]; then
  ok "${ncase} case files: structure, ids, regexes, assertions"
else
  printf '%s' "$struct" | python3 -c "
import json,sys
for p in json.load(sys.stdin)['problems']: print('       -', p)
"
  fail "${nprob} structural problem(s)"
fi

# --- shell validity of every check command -----------------------------------------
# Commands are transported base64-encoded, one per line. A check command is often
# multi-line (an embedded python program), and reading them as raw lines splits one
# command into a dozen fragments that each fail to parse — a validator failing on
# its own transport, reporting twenty defects that do not exist.
bad_syntax=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  cid="${line%%$'\t'*}"
  cmd="$(printf '%s' "${line#*$'\t'}" | base64 -d 2>/dev/null)"
  if ! bash -n -c "$cmd" 2>/dev/null; then
    fail "${cid}: check command is not valid shell: $(printf '%s' "$cmd" | head -1 | cut -c1-70)"
    bad_syntax=1
  fi
done < <(python3 - "$CASE_DIR" <<'PY'
import base64, json, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    try:
        c = json.loads(f.read_text())
    except Exception:
        continue
    for cmd in c.get("check", []) or []:
        enc = base64.b64encode(cmd.encode()).decode()
        print(f"{c.get('id', f.stem)}\t{enc}")
PY
)
[[ $bad_syntax -eq 0 ]] && ok "every check command parses as shell"

# --- RED BEFORE: the case must not already be green -------------------------------
# Run each case's setup in a scratch dir, then its checks. At least one check has to
# fail. If they all pass with no agent involved, the case is measuring the setup.
while IFS= read -r cid; do
  [[ -n "$cid" ]] || continue
  work="${TMP}/${cid}"
  mkdir -p "$work"
  ( cd "$work" && python3 - "${CASE_DIR}/${cid}.json" <<'PY' >/dev/null 2>&1
import json, subprocess, sys
for s in json.load(open(sys.argv[1])).get("setup", []):
    subprocess.run(["bash", "-c", s])
PY
  )
  res="$(cd "$work" && python3 - "${CASE_DIR}/${cid}.json" <<'PY'
import json, subprocess, sys
checks = json.load(open(sys.argv[1])).get("check", [])
passed = [i + 1 for i, c in enumerate(checks)
          if subprocess.run(["bash", "-c", c], capture_output=True).returncode == 0]
print(f"{len(passed)}/{len(checks)}")
PY
  )"
  npass="${res%%/*}"; ntot="${res##*/}"
  if [[ "$npass" == "$ntot" ]]; then
    fail "${cid}: all ${ntot} checks already pass on the bare setup — the case grades nothing"
  else
    ok "${cid}: red before the agent runs (${npass}/${ntot} pass on setup alone)"
  fi
done < <(python3 - "$CASE_DIR" <<'PY'
import json, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    try:
        c = json.loads(f.read_text())
    except Exception:
        continue
    if c.get("check"):
        print(c.get("id", f.stem))
PY
)

echo
if [[ $fails -eq 0 ]]; then
  echo "PASS test-eval-cases.sh"
else
  echo "FAIL test-eval-cases.sh ($fails)"
  exit 1
fi
