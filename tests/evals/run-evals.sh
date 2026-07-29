#!/usr/bin/env bash
# Behavioural evals: does the plugin change what the agent does?
#
# Runs each case twice — once in a scratch project with the plugin's skills and hooks
# installed ("with"), once in a bare project ("without") — and grades both. See README.md.
#
# Requires: claude CLI on PATH, python3, jq-free (uses python3 for JSON).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVAL_DIR="${ROOT}/tests/evals"
CASE_DIR="${EVAL_DIR}/cases"
OUT_DIR="${EVAL_DIR}/results"
# Scratch projects MUST live outside this repo. Inside it, `claude -p` walks up and loads
# the repo's own CLAUDE.md, which carries the protocol — contaminating the "without" arm.
WORK_ROOT="${TMPDIR:-/tmp}/llm-orch-evals"

N=3
ONLY_CASE=""
ARMS="without with"
# Pin the eval model explicitly. The session default may be an exhausted or
# unavailable model (a limit notice comes back as a normal-looking result at
# $0 and silently poisons every row), so never inherit it.
MODEL="${ORCH_EVAL_MODEL:-opus}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n)     N="$2"; shift 2 ;;
    --case)  ONLY_CASE="$2"; shift 2 ;;
    --arm)   ARMS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v claude >/dev/null 2>&1 || { echo "claude CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$WORK_ROOT"
# Per-case output when --case is given, so parallel single-case invocations
# don't clobber each other; merge with merge-results.sh or jq/cat afterwards.
RESULTS="${OUT_DIR}/raw${ONLY_CASE:+.$ONLY_CASE}.jsonl"
BENCH="${OUT_DIR}/benchmark${ONLY_CASE:+.$ONLY_CASE}.json"
: > "$RESULTS"

# --- scratch project construction ------------------------------------------------
# "with" gets the plugin's skills + agents + the hook wiring, rewritten to absolute
# paths so the scratch copy is self-contained. "without" gets nothing.
build_project() {
  local arm="$1" dir="$2" case_file="$3"
  rm -rf "$dir"; mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null || true

  if [[ "$arm" == "with" ]]; then
    cp -R "${ROOT}/skills" "$dir/.claude/skills"
    cp -R "${ROOT}/agents" "$dir/.claude/agents"
    python3 - "$ROOT" "$dir" "$case_file" <<'PY'
import json, sys, pathlib
root, dest, case_file = sys.argv[1], sys.argv[2], sys.argv[3]
case = json.load(open(case_file))
hooks = json.load(open(f"{root}/hooks/hooks.json"))
raw = json.dumps(hooks).replace("${CLAUDE_PLUGIN_ROOT}", root)
# Isolate all plugin state (evidence ledgers, caches) inside the scratch dir,
# and apply any per-case env for the with arm (hook ablations etc.).
env = {"ORCH_HOOK_PROFILE": "standard", "ORCH_HOME": f"{dest}/.orch-home"}
env.update(case.get("with_env", {}))
settings = {"hooks": json.loads(raw)["hooks"], "env": env}
pathlib.Path(f"{dest}/.claude/settings.json").write_text(json.dumps(settings, indent=2))
PY
  fi
}

run_case() {
  local case_file="$1" arm="$2" iter="$3"
  local cid; cid="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$case_file")"
  local prompt; prompt="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['prompt'])" "$case_file")"
  local dir="${WORK_ROOT}/${cid}-${arm}-${iter}"

  build_project "$arm" "$dir" "$case_file"

  # per-case setup commands, run inside the scratch project
  python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1])).get('setup',[])))" "$case_file" \
    | ( cd "$dir" && bash -s ) >/dev/null 2>&1 || true

  # --dangerously-skip-permissions: a non-interactive run cannot answer
  # permission prompts, and a denied Edit turns every write-case into a
  # spurious Blocked. The scratch project is throwaway and outside the repo,
  # so skipping is safe by construction.
  local out
  out="$( cd "$dir" && claude -p "$prompt" --model "$MODEL" --output-format json --dangerously-skip-permissions 2>/dev/null )"

  # behavioural checks against the real filesystem: every command in the case's
  # "check" array must exit 0 inside the scratch project. This is what lets a
  # case grade "did the fix actually work" instead of "did the prose look right".
  local check_rc=0 check_cmds
  check_cmds="$(python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1])).get('check',[])))" "$case_file")"
  if [[ -n "$check_cmds" ]]; then
    ( cd "$dir" && bash -e -c "$check_cmds" ) >/dev/null 2>&1 || check_rc=1
  fi

  python3 - "$case_file" "$arm" "$iter" "$out" "$check_rc" >> "$RESULTS" <<'PY'
import json, re, sys
case = json.load(open(sys.argv[1])); arm, it, raw = sys.argv[2], int(sys.argv[3]), sys.argv[4]
check_rc = int(sys.argv[5])
try:
    obj = json.loads(raw); text = obj.get("result") or ""
    cost = obj.get("total_cost_usd"); err = bool(obj.get("is_error"))
except Exception:
    text, cost, err = "", None, True

exp = case.get("expect", {})
checks = []
for pat in exp.get("must_match", []):
    checks.append({"kind": "must_match", "pattern": pat,
                   "ok": bool(re.search(pat, text, re.M | re.I))})
for pat in exp.get("must_not_match", []):
    checks.append({"kind": "must_not_match", "pattern": pat,
                   "ok": not re.search(pat, text, re.M | re.I)})
# must_open_with: the reply's FIRST non-empty line must start with the literal
# prefix — the protocol's actual rule ("opens with"), which a multiline regex
# match anywhere in the reply is too lax to test.
for prefix in exp.get("must_open_with", []):
    first = text.lstrip().split("\n", 1)[0] if text.strip() else ""
    checks.append({"kind": "must_open_with", "pattern": prefix,
                   "ok": first.startswith(prefix)})
if case.get("check"):
    checks.append({"kind": "check_cmds", "pattern": "; ".join(case["check"]),
                   "ok": check_rc == 0})

print(json.dumps({
    "case": case["id"], "arm": arm, "iter": it,
    "pass": (not err) and all(c["ok"] for c in checks) and bool(checks),
    "error": err, "cost_usd": cost, "checks": checks,
    "text": text[:2000],
}))
PY
}

echo "== behavioural evals =="
echo "cases: $(ls -1 "$CASE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')   arms: ${ARMS}   n: ${N}"
echo

for case_file in "$CASE_DIR"/*.json; do
  [[ -f "$case_file" ]] || { echo "no cases found in $CASE_DIR" >&2; exit 1; }
  cid="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$case_file")"
  [[ -n "$ONLY_CASE" && "$cid" != "$ONLY_CASE" ]] && continue
  for arm in $ARMS; do
    for i in $(seq 1 "$N"); do
      printf '  %-28s %-8s %d/%d ... ' "$cid" "$arm" "$i" "$N"
      run_case "$case_file" "$arm" "$i"
      tail -1 "$RESULTS" | python3 -c "import json,sys;r=json.load(sys.stdin);print('PASS' if r['pass'] else 'FAIL')"
    done
  done
done

python3 - "$RESULTS" "$BENCH" "$MODEL" <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
agg = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    agg[r["case"]][r["arm"]].append(r)

summary = {}
print("\n== summary ==")
print(f"{'case':<28} {'without':>9} {'with':>9} {'$/solved(w/o)':>13} {'$/solved(w)':>12}   verdict")
for case, arms in sorted(agg.items()):
    rate = {a: sum(x["pass"] for x in v) / len(v) for a, v in arms.items()}
    # cost per SOLVED task, per arm — the metric that stays informative when
    # pass-rate deltas sit inside the noise floor.
    cps = {}
    for a, v in arms.items():
        solved = sum(x["pass"] for x in v)
        spent = sum(x["cost_usd"] or 0 for x in v)
        cps[a] = round(spent / solved, 4) if solved else None
    w, o = rate.get("with"), rate.get("without")
    if w is None or o is None:
        verdict = "single-arm"
    elif w > o:   verdict = "plugin helps"
    elif w == o == 1.0: verdict = "already default — rule may be dead weight"
    elif w == o:  verdict = "no effect"
    else:         verdict = "PLUGIN HURTS"
        # Behavioural sub-rate: check_cmds only (held-out execution), so a case
    # whose aggregate is dominated by protocol regexes cannot masquerade as a
    # task-success delta.
    beh = {}
    for a, v in arms.items():
        cc = [all(c["ok"] for c in x["checks"] if c["kind"] == "check_cmds")
              for x in v if any(c["kind"] == "check_cmds" for c in x["checks"])]
        beh[a] = round(sum(cc) / len(cc), 3) if cc else None
    summary[case] = {"with": w, "without": o, "verdict": verdict,
                     "behavioral": beh,
                     "cost_per_solved": cps,
                     "n": {a: len(v) for a, v in arms.items()},
                     "cost_usd": round(sum(x["cost_usd"] or 0 for v in arms.values() for x in v), 4)}
    fmt = lambda x: "  n/a  " if x is None else f"{x*100:5.0f}%  "
    fmtc = lambda x: "   n/a " if x is None else f"${x:.3f}"
    print(f"{case:<28} {fmt(o):>9} {fmt(w):>9} {fmtc(cps.get('without')):>13} {fmtc(cps.get('with')):>12}   {verdict}")

total = round(sum(s["cost_usd"] for s in summary.values()), 2)
print(f"\ntotal cost: ${total}")
print("note: single-run pass rates carry >=1.5pp std at temperature 0; treat a one-run gap as noise.")
out = {"model": sys.argv[3], "cases": summary, "total_cost_usd": total}
# Preserve hand-written analysis across regenerations instead of deleting it.
import os
if os.path.exists(sys.argv[2]):
    try:
        prev = json.load(open(sys.argv[2]))
        for k in ("interpretation", "method_notes", "date", "n_per_arm"):
            if k in prev and k not in out:
                out[k] = prev[k]
        if "interpretation" in out:
            out["interpretation_note"] = "interpretation/method_notes carried over from a PRIOR run — re-derive them from the new raw rows before citing."
    except Exception:
        pass
json.dump(out, open(sys.argv[2], "w"), indent=2)
PY

echo
echo "raw:       ${RESULTS}"
echo "benchmark: ${BENCH}"
