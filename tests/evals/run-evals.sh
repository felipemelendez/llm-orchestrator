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
# don't clobber each other; concatenate the per-case raw files to merge.
#
# Each run also gets its own timestamped pair, and history is append-only. The
# stable names used to be the only ones: a 200-run confirmation of a measured
# regression overwrote the raw rows that proved the regression, so the run
# checking the finding destroyed the evidence for it. The stable names now hold
# a copy of the most recent run, kept only so existing docs and tooling resolve.
RUN_ID="${ORCH_EVAL_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
STEM="${ONLY_CASE:+.$ONLY_CASE}"
RESULTS="${OUT_DIR}/raw${STEM}.${RUN_ID}.jsonl"
BENCH="${OUT_DIR}/benchmark${STEM}.${RUN_ID}.json"
RESULTS_LATEST="${OUT_DIR}/raw${STEM}.jsonl"
BENCH_LATEST="${OUT_DIR}/benchmark${STEM}.json"
: > "$RESULTS"

# --- arm sources ------------------------------------------------------------------
# An arm names WHICH plugin the scratch project gets:
#   without      nothing (bare model)
#   with         the working tree — what you are about to ship
#   ref:<gitref> the plugin as of that commit
#
# The `ref:` arm is what makes this a regression instrument rather than only an
# existence proof. Comparing "with" against "without" answers *does the plugin
# do anything*; it cannot answer *did this week's edit make it better or
# worse*, which is the question every compression pass raises. Anthropic's own
# instruction is to set a baseline you can measure against, and a baseline you
# cannot reconstruct is not one.
#
#   ./run-evals.sh --arm "ref:4f6815f with" --case tdd-bugfix --n 5
#
# materialize_ref exports a whole commit once and caches it, so N iterations
# pay for one export.
materialize_ref() {
  local ref="$1" sha out
  sha="$(git -C "$ROOT" rev-parse --short=12 "$ref" 2>/dev/null)" || {
    echo "run-evals: unknown git ref: $ref" >&2; return 1; }
  out="${WORK_ROOT}/.refs/${sha}"
  # The sentinel, not the directory, is the cache key: a Ctrl-C mid-extract
  # otherwise leaves a partial tree that every later run reuses forever, and a
  # half-populated baseline is worse than none because it looks valid.
  if [[ ! -f "${out}/.complete" ]]; then
    rm -rf "$out"; mkdir -p "$out"
    # A whole-tree export, not just skills/: the hook scripts and libs of that
    # commit are part of what the arm is testing. Exporting only the markdown
    # would silently pair old prose with new enforcement.
    git -C "$ROOT" archive "$sha" | tar -x -C "$out" || { rm -rf "$out"; return 1; }
    : > "${out}/.complete"
  fi
  printf '%s\n' "$out"
}

# --- scratch project construction ------------------------------------------------
# A plugin arm gets skills + agents + the hook wiring, rewritten to absolute
# paths so the scratch copy is self-contained. "without" gets nothing.
build_project() {
  local arm="$1" dir="$2" case_file="$3"
  rm -rf "$dir"; mkdir -p "$dir/.claude"
  git -C "$dir" init -q 2>/dev/null || true

  local src=""
  case "$arm" in
    without) return 0 ;;
    with)    src="$ROOT" ;;
    ref:*)   src="$(materialize_ref "${arm#ref:}")" || return 1 ;;
    *)       echo "run-evals: unknown arm: $arm" >&2; return 1 ;;
  esac

  if [[ -n "$src" ]]; then
    cp -R "${src}/skills" "$dir/.claude/skills"
    cp -R "${src}/agents" "$dir/.claude/agents"
    python3 - "$src" "$dir" "$case_file" <<'PY'
import json, sys, pathlib
root, dest, case_file = sys.argv[1], sys.argv[2], sys.argv[3]
case = json.load(open(case_file))
hooks = json.load(open(f"{root}/hooks/hooks.json"))
raw = json.dumps(hooks).replace("${CLAUDE_PLUGIN_ROOT}", root)
# Isolate all plugin state (evidence ledgers, caches) inside the scratch dir,
# and apply any per-case env for the with arm (hook ablations etc.).
# ORCH_TELEMETRY=1 arms the skill-telemetry hook so every run records which
# skills it invoked — the raw rows carry the answer natively instead of it
# having to be mined out of session transcripts after the fact.
env = {"ORCH_HOOK_PROFILE": "standard", "ORCH_HOME": f"{dest}/.orch-home",
       "ORCH_TELEMETRY": "1"}
env.update(case.get("with_env", {}))
settings = {"hooks": json.loads(raw)["hooks"], "env": env}
pathlib.Path(f"{dest}/.claude/settings.json").write_text(json.dumps(settings, indent=2))
PY
  fi
}

run_case() {
  local case_file="$1" arm="$2" iter="$3"
  local cid; cid="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$case_file")"
  local dir="${WORK_ROOT}/${cid}-${arm}-${iter}"

  # Variant families: a case MAY carry "variants" — a list of COMPLETE,
  # independent scenarios (no field merging with the base; merging is where
  # merge bugs live). scenarios = [base] + variants, and iteration i (1-based)
  # runs scenarios[(i-1) % len(scenarios)]: prompt, setup, grading checks and
  # expect all come from that one scenario. A single frozen task instance is
  # easy to Goodhart; a family samples the construct.
  # Scenario materialization must NOT fall through into a paid run. Unchecked, a
  # malformed variant (missing field, non-object entry) crashed this heredoc and
  # `claude -p ""` still ran and recorded a normal-looking row — same failure
  # class as the build_project guard below, so it aborts the same way.
  local scen_file="${WORK_ROOT}/${cid}-${arm}-${iter}.scenario.json"
  if ! python3 - "$case_file" "$iter" > "$scen_file" <<'PY'
import json, sys
case = json.load(open(sys.argv[1])); it = int(sys.argv[2])
scenarios = [{"name": "base", "prompt": case["prompt"],
              "setup": case.get("setup", []), "check": case.get("check", []),
              "expect": case.get("expect", {})}]
for v in case.get("variants", []):
    scenarios.append({"name": v["name"], "prompt": v["prompt"],
                      "setup": v.get("setup", []), "check": v.get("check", []),
                      "expect": v.get("expect", {})})
s = scenarios[(it - 1) % len(scenarios)]
if not (isinstance(s.get("prompt"), str) and s["prompt"].strip()):
    sys.stderr.write("scenario %r has an empty or non-string prompt\n" % s.get("name"))
    sys.exit(1)
s["case_id"] = case["id"]
print(json.dumps(s))
PY
  then
    echo "run-evals: could not materialize scenario for case '$cid' iter $iter (malformed variant or missing field) — aborting rather than paying for an ungraded run" >&2
    exit 1
  fi
  if [[ ! -s "$scen_file" ]]; then
    echo "run-evals: empty scenario file for case '$cid' iter $iter — aborting rather than paying for an ungraded run" >&2
    exit 1
  fi
  local prompt
  if ! prompt="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['prompt'])" "$scen_file")" \
     || [[ -z "$prompt" ]]; then
    echo "run-evals: could not extract the prompt for case '$cid' iter $iter — aborting rather than running 'claude -p \"\"'" >&2
    exit 1
  fi

  # A failed build must NOT fall through into a paid run. Unchecked, a one-char
  # typo in `--arm ref:<sha>` produced a BARE scratch project that still ran
  # `claude -p` and recorded rows labelled with the ref — so a compression pass
  # would "validate" against a plugin-less arm masquerading as its baseline.
  # That is the exact failure this arm exists to prevent, so it aborts.
  if ! build_project "$arm" "$dir" "$case_file"; then
    echo "run-evals: could not build arm '$arm' — aborting rather than running a mislabelled arm" >&2
    exit 1
  fi

  # per-scenario setup commands, run inside the scratch project
  python3 -c "import json,sys;print('\n'.join(json.load(open(sys.argv[1])).get('setup',[])))" "$scen_file" \
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
  # Graded ONE COMMAND AT A TIME, not as a single `bash -e` conjunction. A case
  # can then carry two independent measurements — reviewer recall and reviewer
  # precision are the first pair — and the summary can report each separately
  # instead of collapsing them into one bit that says only "something failed".
  local check_json
  check_json="$(python3 - "$scen_file" "$dir" <<'PY'
import json, subprocess, sys
case = json.load(open(sys.argv[1]))
out = []
for cmd in case.get("check", []):
    r = subprocess.run(["bash", "-c", cmd], cwd=sys.argv[2], capture_output=True)
    out.append(r.returncode == 0)
print(json.dumps(out))
PY
)"

  # Skill-invocation telemetry harvest. [] and null mean DIFFERENT things:
  #   []   the instrument existed and recorded zero invocations — that is data;
  #   null the arm carried no instrument at all — absence of measurement.
  # The without arm, and ref trees that predate scripts/hooks/skill-telemetry.sh,
  # record null; a plugin arm whose telemetry file is simply absent recorded
  # zero invocations and gets []. On 2026-08-04 a regression's mechanism —
  # skill invocation dropping from ~23% to 0% — had to be mined out of session
  # transcripts by hand; this field makes every future run carry that answer.
  local tel_src="" skills_json="null"
  case "$arm" in
    with)  tel_src="$ROOT" ;;
    ref:*) tel_src="$(materialize_ref "${arm#ref:}" 2>/dev/null || true)" ;;
  esac
  # "Instrument armed" means armed, not merely present on disk: the script must
  # exist in the arm's tree, be wired into that tree's hooks/hooks.json, and the
  # effective settings env (the runner's defaults overlaid with the case's
  # with_env — which can ablate it) must carry ORCH_TELEMETRY=1 without naming
  # orch-skill-telemetry in ORCH_DISABLED_HOOKS. A tree that ships the script unwired
  # or a case that disables it recorded nothing — that is null (no instrument),
  # not [] (a measured zero).
  local tel_armed=0
  if [[ -n "$tel_src" && -f "${tel_src}/scripts/hooks/skill-telemetry.sh" ]]; then
    if python3 - "$case_file" "${tel_src}/hooks/hooks.json" <<'PY'
import json, sys
case = json.load(open(sys.argv[1]))
try:
    hooks_raw = open(sys.argv[2]).read()
except OSError:
    sys.exit(1)                     # no hooks.json in that tree — never wired
if "skill-telemetry" not in hooks_raw:
    sys.exit(1)                     # script present but not wired as a hook
env = {"ORCH_HOOK_PROFILE": "standard", "ORCH_TELEMETRY": "1"}
env.update(case.get("with_env", {}))   # mirrors build_project's effective env
if str(env.get("ORCH_TELEMETRY", "")) != "1":
    sys.exit(1)
# Mirror the hook's own kill switch exactly (scripts/hooks/skill-telemetry.sh):
# it matches ",${ORCH_DISABLED_HOOKS}," against ",orch-skill-telemetry," — the
# exact token "orch-skill-telemetry", comma-delimited, no whitespace stripping.
# Anything looser here records a measured [] for a run the hook sat out (or
# null for a run it recorded), which is the one lie this field must never tell.
disabled = str(env.get("ORCH_DISABLED_HOOKS", "")).split(",")
if "orch-skill-telemetry" in disabled:
    sys.exit(1)
sys.exit(0)
PY
    then tel_armed=1; fi
  fi
  if (( tel_armed )); then
    skills_json="$(python3 - "${dir}/.orch-home/telemetry/skills.jsonl" <<'PY'
import json, os, sys
names = []
if os.path.exists(sys.argv[1]):
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line:
            continue
        try:
            names.append(json.loads(line)["skill"])
        except Exception:
            pass
print(json.dumps(names))
PY
)"
  fi

  python3 - "$scen_file" "$arm" "$iter" "$out" "$check_json" "$skills_json" >> "$RESULTS" <<'PY'
import json, re, sys
case = json.load(open(sys.argv[1])); arm, it, raw = sys.argv[2], int(sys.argv[3]), sys.argv[4]
try:
    check_results = json.loads(sys.argv[5])
except Exception:
    check_results = []
try:
    skills_invoked = json.loads(sys.argv[6])
except Exception:
    skills_invoked = None
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
    # One entry per command, so a per-check pass rate is recoverable from the raw
    # rows, plus the aggregate the behavioural verdict reads.
    #
    # A grader that crashed returns fewer results than there are checks. That must
    # fail CLOSED and stay diagnosable: scoring it as a pass would credit a run
    # nothing graded, and scoring it as a silent fail would look identical to the
    # model failing the task.
    graded_all = len(check_results) == len(case["check"])
    if not graded_all:
        checks.append({"kind": "check_error", "pattern": "grader returned %d of %d results"
                       % (len(check_results), len(case["check"])), "ok": False})
    for idx, (cmd, ok) in enumerate(zip(case["check"], check_results)):
        checks.append({"kind": "check_one", "index": idx, "pattern": cmd, "ok": bool(ok)})
    checks.append({"kind": "check_cmds", "pattern": "; ".join(case["check"]),
                   "ok": graded_all and all(check_results)})

print(json.dumps({
    "case": case["case_id"], "arm": arm, "iter": it, "variant": case["name"],
    "pass": (not err) and all(c["ok"] for c in checks) and bool(checks),
    "error": err, "cost_usd": cost, "checks": checks,
    "skills_invoked": skills_invoked,
    "text": text[:2000],
}))
PY
}

CONSEC_ERR=0
echo "== behavioural evals =="
echo "cases: $(ls -1 "$CASE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')   arms: ${ARMS}   n: ${N}"
echo

for case_file in "$CASE_DIR"/*.json; do
  [[ -f "$case_file" ]] || { echo "no cases found in $CASE_DIR" >&2; exit 1; }
  cid="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$case_file")"
  [[ -n "$ONLY_CASE" && "$cid" != "$ONLY_CASE" ]] && continue
  # Iterations round-robin the scenario family, so when N is not a multiple of
  # the family size the tail scenarios run fewer iterations — and at N < family
  # size some never run at all. Say so, or a family member silently not being
  # exercised looks identical to it passing.
  scen_n="$(python3 -c "import json,sys;print(1+len(json.load(open(sys.argv[1])).get('variants',[]) or []))" "$case_file")"
  if (( scen_n > 1 && N % scen_n != 0 )); then
    echo "  note: ${cid} has ${scen_n} scenarios and n=${N} — the first $((N % scen_n)) scenario(s) run $((N / scen_n + 1))x per arm, the remaining $((scen_n - N % scen_n)) run $((N / scen_n))x"
  fi
  for arm in $ARMS; do
    for i in $(seq 1 "$N"); do
      printf '  %-28s %-8s %d/%d ... ' "$cid" "$arm" "$i" "$N"
      run_case "$case_file" "$arm" "$i"
      verdict_line="$(tail -1 "$RESULTS" | python3 -c "
import json,sys
r = json.load(sys.stdin)
print('ERROR' if r.get('error') else ('PASS' if r['pass'] else 'FAIL'))")"
      echo "$verdict_line"
      # A run that never reached the model is NOT a failing run. A session-limit
      # notice comes back as a normal-looking result at \$0 and, scored as a
      # FAIL, silently poisons the arm — on 2026-08-04 that produced
      # "WORSE — REGRESSION (2/100 vs 75/100, p=0.000)" out of 94 limit
      # notices. A limit does not heal mid-run, so three in a row aborts rather
      # than spending two more hours manufacturing a confident wrong answer.
      if [[ "$verdict_line" == "ERROR" ]]; then
        CONSEC_ERR=$((CONSEC_ERR + 1))
        if (( CONSEC_ERR >= 3 )); then
          echo >&2
          echo "run-evals: 3 consecutive runs returned no model result — aborting." >&2
          echo "  last text: $(tail -1 "$RESULTS" | python3 -c "
import json,sys; print((json.load(sys.stdin).get('text') or '')[:160])")" >&2
          echo "  Rows already written are marked error:true and are EXCLUDED from rates." >&2
          echo "  Re-run when the model is reachable; partial arms cannot be compared." >&2
          exit 3
        fi
      else
        CONSEC_ERR=0
      fi
    done
  done
done

ORCH_EVAL_BENCH_LATEST="$BENCH_LATEST" python3 - "$RESULTS" "$BENCH" "$MODEL" "$ARMS" <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]

# Rows where the model never answered are NOT data. They used to be counted as
# failing runs, which is how a session limit produced a p=0.000 "REGRESSION"
# against an arm that had simply stopped being asked. Excluded from every rate,
# counted, and loud enough to invalidate the verdict.
errored = collections.defaultdict(lambda: collections.defaultdict(int))
for r in rows:
    if r.get("error"):
        errored[r["case"]][r["arm"]] += 1
rows = [r for r in rows if not r.get("error")]

agg = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    agg[r["case"]][r["arm"]].append(r)

def fisher_exact_two_tailed(a, b, c, d):
    """Two-tailed Fisher exact p for the 2x2 [[a,b],[c,d]].

    Sums the probability of every table at least as extreme as the observed
    one, conditioning on the margins. Exact — no normal approximation, which
    is wrong at the sample sizes a paid eval can afford.
    """
    from math import comb
    n = a + b + c + d
    if n == 0 or (a + b) == 0 or (c + d) == 0 or (a + c) == 0 or (b + d) == 0:
        return 1.0
    def prob(x):
        # hypergeometric: x successes in the first arm, margins fixed
        return (comb(a + c, x) * comb(b + d, (a + b) - x)) / comb(n, a + b)
    observed = prob(a)
    lo = max(0, (a + b) - (b + d))
    hi = min(a + c, a + b)
    # 1e-9 absorbs float wobble so a table exactly as likely as the observed
    # one is counted, which is what "at least as extreme" means.
    return min(1.0, sum(prob(x) for x in range(lo, hi + 1)
                        if prob(x) <= observed + 1e-9))


summary = {}
# Arms in the order the CLI listed them, so no comparison depends on sha spelling.
arm_order = [a for a in sys.argv[4].split()] if len(sys.argv) > 4 else []
print("\n== summary ==")
print(f"{'case':<28} {'BEHAVIOUR base':>14} {'BEHAVIOUR test':>14} "
      f"{'SHAPE base':>10} {'SHAPE test':>10} "
      f"{'overall base':>12} {'overall test':>12} {'$/solved':>9}   verdict")
print(f"{'':<28} {'(ref: if present, else without)':>44}")
for case, arms in sorted(agg.items()):
    rate = {a: sum(x["pass"] for x in v) / len(v) for a, v in arms.items()}
    for a in arms:                       # arms present in the rows but not on the CLI
        if a not in arm_order:
            arm_order.append(a)
    extra_verdicts = []
    # cost per SOLVED task, per arm — the metric that stays informative when
    # pass-rate deltas sit inside the noise floor.
    cps = {}
    for a, v in arms.items():
        solved = sum(x["pass"] for x in v)
        spent = sum(x["cost_usd"] or 0 for x in v)
        cps[a] = round(spent / solved, 4) if solved else None
    # Behavioural rate: the held-out execution checks only, per arm. This is the
    # HEADLINE, not a footnote. On the run that mattered, the overall rate mixed
    # protocol-format regexes into the pass criterion and printed p=0.46
    # "inconclusive" while the behaviour underneath had moved 76/100 -> 56/100 at
    # p=0.004. Format noise swamped the signal the run was bought to find.
    beh_n = {}
    for a, v in arms.items():
        cc = [all(c["ok"] for c in x["checks"] if c["kind"] == "check_cmds")
              for x in v if any(c["kind"] == "check_cmds" for c in x["checks"])]
        beh_n[a] = (sum(cc), len(cc)) if cc else None
    beh = {a: (round(t[0] / t[1], 3) if t else None) for a, t in beh_n.items()}

    # Shape rate: the expect-derived checks only (must_match / must_not_match /
    # must_open_with), per arm. Reported beside the behavioural rate, never
    # mixed into it — format noise swamping the behavioural signal is the exact
    # failure the behavioural headline exists to prevent. Denominator: rows
    # carrying at least one expect-derived check.
    SHAPE_KINDS = ("must_match", "must_not_match", "must_open_with")
    shape = {}
    for a, v in arms.items():
        sc = [all(c["ok"] for c in x["checks"] if c["kind"] in SHAPE_KINDS)
              for x in v if any(c["kind"] in SHAPE_KINDS for c in x["checks"])]
        shape[a] = round(sum(sc) / len(sc), 3) if sc else None

    # Skill-invocation telemetry, per arm. Denominator = rows where the
    # instrument existed (skills_invoked is not null); [] counts as a measured
    # zero. Rows without the field (old raw files, the without arm) are
    # absence of instrument, not zero — they are excluded, and an arm with no
    # measured rows reports None rather than a fake 0%.
    skills = {}
    for a, v in arms.items():
        meas = [x for x in v if x.get("skills_invoked") is not None]
        if not meas:
            skills[a] = None
            continue
        counts = collections.Counter()
        for x in meas:
            counts.update(x["skills_invoked"])
        inv = sum(1 for x in meas if x["skills_invoked"])
        skills[a] = {"rate": round(inv / len(meas), 3),
                     "invoked_runs": inv, "measured_runs": len(meas),
                     "counts": dict(counts)}

    # Per-variant behavioural rates. The case-level aggregate above stays the
    # headline — all variants measure one construct and are pooled — but the
    # split is stored so a variant that alone drags the family down is visible.
    per_variant = {}
    for a, v in arms.items():
        by = {}
        for x in v:
            by.setdefault(x.get("variant", "base"), []).append(x)
        pv = {}
        for name, xs in sorted(by.items()):
            cc = [all(c["ok"] for c in x["checks"] if c["kind"] == "check_cmds")
                  for x in xs if any(c["kind"] == "check_cmds" for c in x["checks"])]
            pv[name] = round(sum(cc) / len(cc), 3) if cc else None
        per_variant[a] = pv

    # An arm that lost a material share of its runs cannot be compared to one
    # that did not. Report the loss; do not quietly compare what survived.
    errs = errored.get(case, {})
    invalid = []
    for a in set(list(arms.keys()) + list(errs.keys())):
        e = errs.get(a, 0)
        total = e + len(arms.get(a, []))
        if total and e / total > 0.10:
            invalid.append("%s %d/%d runs never reached the model" % (a, e, total))

    w, o = rate.get("with"), rate.get("without")
    # A `ref:<sha>` arm is a PLUGIN VERSION, so the interesting comparison is
    # with-vs-ref (did this week's edit help?), not with-vs-without (does the
    # plugin do anything?). Reporting only the latter left the version
    # comparison computed and invisible — the run cost money and printed
    # "single-arm", which is how a regression ships unnoticed.
    # Arm order as the CLI gave it, not sorted: with two `ref:` arms the old code
    # compared against whichever sha spelled lowest in hex, so the baseline you got
    # depended on the spelling of a commit id. Every ref arm now gets its own
    # verdict line, and none is silently dropped.
    ref_arms = [a for a in arm_order if a in rate and a.startswith("ref:")]
    ref_arm = ref_arms[0] if ref_arms else None
    r = rate.get(ref_arm) if ref_arm else None
    # The treatment arm is `with` when present, otherwise the single non-ref arm.
    # `--arm "ref:X without"` is a legal two-arm comparison and used to print
    # "single-arm", discarding a result that had already been paid for.
    non_ref = [a for a in arm_order if a in rate and not a.startswith("ref:")]
    test_arm = "with" if "with" in rate else (non_ref[0] if len(non_ref) == 1 else None)
    if test_arm is not None and ref_arm is not None:
        # A RATE COMPARISON IS NOT A RESULT. At n=5, 3/5 vs 2/5 is one run, and
        # this printed "REGRESSION" for it — the same overclaiming this harness
        # exists to catch, relocated into the reporter. The README already says
        # a one-run gap is noise; the verdict now has to agree with it.
        #
        # Fisher's exact test on the 2x2 (pass/fail x arm). Exact, stdlib-only,
        # correct at the small n these runs can afford — no normal approximation
        # that misbehaves on 5 samples.
        # Test the BEHAVIOURAL counts when the case has execution checks; fall
        # back to overall only for cases that are purely about the reply text.
        if beh_n.get(test_arm) and beh_n.get(ref_arm):
            (pw, nw), (pr, nr) = beh_n[test_arm], beh_n[ref_arm]
            basis, cw, cr = "behaviour", beh[test_arm], beh[ref_arm]
        else:
            pw = sum(x["pass"] for x in arms[test_arm]); nw = len(arms[test_arm])
            pr = sum(x["pass"] for x in arms[ref_arm]); nr = len(arms[ref_arm])
            basis, cw, cr = "overall", rate[test_arm], rate[ref_arm]
        p_value = fisher_exact_two_tailed(pw, nw - pw, pr, nr - pr)
        gap = f"{basis} {test_arm} {pw}/{nw} vs {pr}/{nr}"
        if p_value >= 0.05:
            verdict = f"inconclusive ({gap}, p={p_value:.2f} — need more runs)"
        elif cw > cr:
            verdict = f"BETTER than {ref_arm} ({gap}, p={p_value:.3f})"
        else:
            verdict = f"WORSE than {ref_arm} — REGRESSION ({gap}, p={p_value:.3f})"
        for extra in ref_arms[1:]:
            if beh_n.get(test_arm) and beh_n.get(extra):
                (aw, an), (ar, anr) = beh_n[test_arm], beh_n[extra]
                b2 = "behaviour"
            else:
                aw = sum(x["pass"] for x in arms[test_arm]); an = len(arms[test_arm])
                ar = sum(x["pass"] for x in arms[extra]); anr = len(arms[extra])
                b2 = "overall"
            p2 = fisher_exact_two_tailed(aw, an - aw, ar, anr - ar)
            extra_verdicts.append(
                f"also vs {extra}: {b2} {aw}/{an} vs {ar}/{anr}, p={p2:.3f}"
                + ("" if p2 >= 0.05 else ("  <-- BETTER" if aw / an > ar / anr else "  <-- REGRESSION")))
    elif w is None or o is None:
        verdict = "single-arm"
    elif w > o:   verdict = "plugin helps"
    elif w == o == 1.0: verdict = "already default — rule may be dead weight"
    elif w == o:  verdict = "no effect"
    else:         verdict = "PLUGIN HURTS"
    # Per-check rates, so a case carrying two independent measurements (recall
    # and precision, say) reports them separately instead of as one bit.
    # Check indices are PER-SCENARIO: with variants, index i is a different
    # command in each scenario, so pooling by bare index mixed unrelated
    # commands under whichever label came first. When variants are present the
    # aggregation key is "<variant>:<index>"; without them it stays "<index>"
    # so existing consumers of variant-less cases are unchanged.
    per_check = {}
    per_check_label = {}
    has_variants = any(x.get("variant", "base") != "base"
                       for v in arms.values() for x in v)
    for a, v in arms.items():
        idx_ok, idx_pat = {}, {}
        for x in v:
            vn = x.get("variant", "base")
            for c in x["checks"]:
                if c["kind"] == "check_one":
                    key = (vn, c["index"]) if has_variants else ("", c["index"])
                    idx_ok.setdefault(key, []).append(c["ok"])
                    idx_pat.setdefault(key, c.get("pattern", ""))
        if idx_ok:
            kstr = lambda k: (f"{k[0]}:{k[1]}" if has_variants else str(k[1]))
            per_check[a] = {kstr(k): round(sum(o) / len(o), 3)
                            for k, o in sorted(idx_ok.items())}
            per_check_label[a] = {
                kstr(k): (f"[{k[0]}] " if has_variants else "") + idx_pat[k]
                for k in sorted(idx_ok)}

    if invalid:
        verdict = "INVALID — " + "; ".join(sorted(invalid)) + " (re-run; not a result)"

    summary[case] = {"with": w, "without": o, "verdict": verdict,
                     "test_arm": test_arm, "extra_verdicts": extra_verdicts,
                     "ref_arm": ref_arm, "ref": r,
                     "rates": rate,
                     "behavioral": beh,
                     "behavioral_counts": {a: (list(t) if t else None)
                                           for a, t in beh_n.items()},
                     "shape": shape,
                     "skills": skills,
                     "per_variant": per_variant,
                     "per_check": per_check,
                     "errored_runs": dict(errs),
                     "invalid": invalid,
                     "check_cmds": (agg[case] and next(
                         ([c["pattern"] for c in x["checks"] if c["kind"] == "check_one"]
                          for v in arms.values() for x in v
                          if any(c["kind"] == "check_one" for c in x["checks"])), [])),
                     "cost_per_solved": cps,
                     "n": {a: len(v) for a, v in arms.items()},
                     "cost_usd": round(sum(x["cost_usd"] or 0 for v in arms.values() for x in v), 4)}
    fmt = lambda x: "  n/a  " if x is None else f"{x*100:5.0f}%  "
    fmtc = lambda x: "   n/a " if x is None else f"${x:.3f}"
    base_arm = ref_arm or "without"
    show_arm = test_arm or "with"
    print(f"{case:<28} {fmt(beh.get(base_arm)):>14} {fmt(beh.get(show_arm)):>14} "
          f"{fmt(shape.get(base_arm)):>10} {fmt(shape.get(show_arm)):>10} "
          f"{fmt(rate.get(base_arm)):>12} {fmt(rate.get(show_arm)):>12} "
          f"{fmtc(cps.get(show_arm)):>9}   {verdict}")
    for ev in extra_verdicts:
        print(f"    {'':<12} {ev}")
    # One skills line per case-arm: invocation rate over the measured rows,
    # plus which skills fired. "n/a (not captured)" is an arm with no
    # instrument — distinct from a measured 0%.
    for a in [x for x in arm_order if x in arms]:
        s = skills.get(a)
        if s is None:
            print(f"    {a:<12} skills: n/a (not captured)")
        else:
            top = ", ".join(f"{k} x{n}" for k, n in
                            sorted(s["counts"].items(), key=lambda kv: (-kv[1], kv[0])))
            print(f"    {a:<12} skills: {s['invoked_runs']}/{s['measured_runs']} runs invoked >=1 skill"
                  + (f"   ({top})" if top else ""))
    for a, d in sorted(per_check.items()):
        labels = per_check_label.get(a, {})
        for k, v in d.items():   # built sorted: variant name, then index
            label = labels.get(k) or f"check {k}"
            if len(label) > 58:
                label = label[:58] + "…"
            idx = int(k.rsplit(":", 1)[-1])
            print(f"    {a:<12} check{idx+1}: {v*100:5.1f}%   {label}")

total = round(sum(s["cost_usd"] for s in summary.values()), 2)
print(f"\ntotal cost: ${total}")
print("note: single-run pass rates carry >=1.5pp std at temperature 0; treat a one-run gap as noise.")
out = {"model": sys.argv[3], "cases": summary, "total_cost_usd": total}
# Preserve hand-written analysis across regenerations instead of deleting it.
import os
prev_stable = os.environ.get("ORCH_EVAL_BENCH_LATEST", "")
if prev_stable and os.path.exists(prev_stable):
    try:
        prev = json.load(open(prev_stable))
        for k in ("interpretation", "method_notes", "date", "n_per_arm"):
            if k in prev and k not in out:
                out[k] = prev[k]
        if "interpretation" in out:
            out["interpretation_note"] = "interpretation/method_notes carried over from a PRIOR run — re-derive them from the new raw rows before citing."
    except Exception:
        pass
json.dump(out, open(sys.argv[2], "w"), indent=2)
PY

# The stable names are a copy of the newest run, never the only copy of it.
cp "$RESULTS" "$RESULTS_LATEST" 2>/dev/null || true
cp "$BENCH"    "$BENCH_LATEST"  2>/dev/null || true

echo
echo "raw:       ${RESULTS}"
echo "benchmark: ${BENCH}"
echo "latest:    ${RESULTS_LATEST}  ${BENCH_LATEST}   (copies — the timestamped pair is the record)"
