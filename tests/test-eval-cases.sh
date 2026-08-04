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

# A skip is not a pass: under ORCH_REQUIRE_DEPS=1 (set in CI) a missing
# dependency is a hard failure. The git branch below already honoured the flag
# while the python3 line exited 0 SKIP — one file, two contracts; both now go
# through the same helper.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    echo "FAIL: $1 — $2 (ORCH_REQUIRE_DEPS=1)"
    exit 1
  fi
  echo "SKIP: $1 ($2)"
  exit 0
}
command -v python3 >/dev/null 2>&1 || skip_suite test-eval-cases 'python3 not found'
command -v git >/dev/null 2>&1 || skip_suite test-eval-cases 'git not found'
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
    # Variant families: each variant is a COMPLETE, independent scenario — all
    # four fields, no inheritance from the base. A merged/partial variant is a
    # merge bug waiting to grade the wrong thing.
    variants = c.get("variants", [])
    if not isinstance(variants, list):
        problems.append(f"{cid}: 'variants' must be a list"); variants = []
    vnames = set()
    for i, v in enumerate(variants):
        if not isinstance(v, dict):
            problems.append(f"{cid}: variant {i} is not an object"); continue
        name = v.get("name")
        if not (isinstance(name, str) and name.strip()):
            problems.append(f"{cid}: variant {i} has no name"); name = f"<variant {i}>"
        elif not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            # The red-before protocol below transports "<cid>\t<name>" lines; a
            # tab (or any exotic character) in a name corrupts the transport.
            problems.append(f"{cid}: variant {i} name {name!r} must match [A-Za-z0-9._-]+")
        elif name == "base":
            problems.append(f"{cid}: variant name 'base' collides with the top-level scenario")
        elif name in vnames:
            problems.append(f"{cid}: duplicate variant name '{name}'")
        vnames.add(name)
        for k in ("prompt", "setup", "check", "expect"):
            if k not in v:
                problems.append(f"{cid}: variant '{name}' missing '{k}' — variants are complete, not merged")
        for kind in ("must_match", "must_not_match"):
            for pat in (v.get("expect") or {}).get(kind, []):
                try:
                    re.compile(pat)
                except re.error as e:
                    problems.append(f"{cid}: variant '{name}' {kind} pattern does not compile: {pat!r} ({e})")
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
    cid = c.get("id", f.stem)
    for cmd in c.get("check", []) or []:
        enc = base64.b64encode(cmd.encode()).decode()
        print(f"{cid}\t{enc}")
    for v in c.get("variants", []) or []:
        if not isinstance(v, dict):
            continue
        for cmd in v.get("check", []) or []:
            enc = base64.b64encode(cmd.encode()).decode()
            print(f"{cid}[{v.get('name', '?')}]\t{enc}")
PY
)
[[ $bad_syntax -eq 0 ]] && ok "every check command parses as shell"

# --- RED BEFORE: the case must not already be green -------------------------------
# Run each scenario's setup in a scratch dir, then its checks. At least one check has
# to fail. If they all pass with no agent involved, the scenario is measuring the
# setup. EVERY scenario is held to this — the base and each variant independently —
# because a variant that is green on its own setup silently dilutes the family's
# rate on every paid run.
while IFS=$'\t' read -r cid sname; do
  [[ -n "$cid" ]] || continue
  work="${TMP}/red-${cid}-$(printf '%s' "$sname" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$work"
  ( cd "$work" && python3 - "${CASE_DIR}/${cid}.json" "$sname" <<'PY' >/dev/null 2>&1
import json, subprocess, sys
case = json.load(open(sys.argv[1])); name = sys.argv[2]
scen = case if name == "base" else next(
    v for v in case.get("variants", []) if isinstance(v, dict) and v.get("name") == name)
for s in scen.get("setup", []):
    subprocess.run(["bash", "-c", s])
PY
  )
  res="$(cd "$work" && python3 - "${CASE_DIR}/${cid}.json" "$sname" <<'PY'
import json, subprocess, sys
case = json.load(open(sys.argv[1])); name = sys.argv[2]
scen = case if name == "base" else next(
    v for v in case.get("variants", []) if isinstance(v, dict) and v.get("name") == name)
checks = scen.get("check", [])
passed = [i + 1 for i, c in enumerate(checks)
          if subprocess.run(["bash", "-c", c], capture_output=True).returncode == 0]
print(f"{len(passed)}/{len(checks)}")
PY
  )"
  npass="${res%%/*}"; ntot="${res##*/}"
  label="$cid"; [[ "$sname" != "base" ]] && label="${cid}[${sname}]"
  if [[ "$npass" == "$ntot" ]]; then
    fail "${label}: all ${ntot} checks already pass on the bare setup — the scenario grades nothing"
  else
    ok "${label}: red before the agent runs (${npass}/${ntot} pass on setup alone)"
  fi
done < <(python3 - "$CASE_DIR" <<'PY'
import json, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    try:
        c = json.loads(f.read_text())
    except Exception:
        continue
    cid = c.get("id", f.stem)
    if c.get("check"):
        print(f"{cid}\tbase")
    for v in c.get("variants", []) or []:
        if isinstance(v, dict) and v.get("check") and (v.get("name") or "").strip():
            print(f"{cid}\t{v['name']}")
PY
)

echo
if [[ $fails -eq 0 ]]; then
  echo "PASS test-eval-cases.sh"
else
  echo "FAIL test-eval-cases.sh ($fails)"
  exit 1
fi
