#!/usr/bin/env bash
# The eval reporter is the only thing standing between a measured regression and
# a green-looking summary table. On 2026-08-03 it failed that job: a 200-run A/B
# moved test-first behaviour from 76/100 to 56/100 (Fisher p=0.004) and the table
# printed "inconclusive, p=0.46", because the verdict was computed from an
# overall rate that mixes protocol-format regexes into the pass criterion.
#
# This replays the archived numbers from that exact run through the reporter and
# fails if the verdict does not name it a regression. No API calls, no cost —
# the rows are synthesised to the archived margins.
#
# Archive: tests/evals/results/archive/2026-08-03-tdd-under-pressure-REGRESSION-FOUND.json
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/tests/evals/run-evals.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# A skip is not a pass: under ORCH_REQUIRE_DEPS=1 (set in CI) a missing
# dependency is a hard failure — same contract as the other suites' skip_suite
# helper. This line used to exit 0 SKIP unconditionally.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    echo "FAIL: $1 — $2 (ORCH_REQUIRE_DEPS=1)"
    exit 1
  fi
  echo "SKIP: $1 ($2)"
  exit 0
}
command -v python3 >/dev/null 2>&1 || skip_suite test-eval-reporter 'python3 not found'
[[ -f "$RUNNER" ]] || { echo "FAIL: $RUNNER missing"; exit 1; }

echo "== eval reporter =="

# The reporter is the heredoc'd python block at the end of the runner. Extract it
# rather than re-implementing it, so this test cannot drift from what ships.
python3 - "$RUNNER" > "${TMP}/reporter.py" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
# Tolerant of extra arguments on the heredoc line: pinning the exact argv list
# made this test fail the moment the reporter gained a parameter, which is a
# test breaking on a change it was not written to police.
m = re.search(r"python3 - \"\$RESULTS\" \"\$BENCH\" \"\$MODEL\".*?<<'PY'\n(.*?)\nPY\n", src, re.S)
if not m:
    sys.stderr.write("could not locate the summary block in the runner\n")
    sys.exit(1)
sys.stdout.write(m.group(1))
PY
[[ -s "${TMP}/reporter.py" ]] || { echo "  FAIL could not extract the reporter"; exit 1; }

# --- the archived regression -------------------------------------------------------
# ref:4f6815f 76/100 behavioural, 40/100 overall; with 56/100 behavioural, 34/100
# overall. Overall is a subset of behavioural because the format regexes only ever
# subtract, which is what makes the overall rate the noisier of the two.
python3 - > "${TMP}/replay.jsonl" <<'PY'
import json
def rows(arm, beh, overall, n=100):
    for i in range(n):
        b, p = i < beh, i < overall
        checks = [{"kind": "must_open_with", "pattern": "Changed:", "ok": p},
                  {"kind": "check_one", "index": 0, "pattern": "bug fixed", "ok": b},
                  {"kind": "check_one", "index": 1, "pattern": "test written", "ok": b},
                  {"kind": "check_cmds", "pattern": "bug fixed; test written", "ok": b}]
        yield {"case": "tdd-under-pressure", "arm": arm, "iter": i + 1,
               "pass": all(c["ok"] for c in checks), "error": False,
               "cost_usd": 0.35, "checks": checks, "text": ""}
for r in list(rows("ref:4f6815f", 76, 40)) + list(rows("with", 56, 34)):
    print(json.dumps(r))
PY

ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" \
  "${TMP}/replay.jsonl" "${TMP}/bench.json" opus >"${TMP}/out.txt" 2>&1 || true

if [[ ! -f "${TMP}/bench.json" ]]; then
  fail "reporter produced no benchmark file"
else
  verdict="$(python3 -c "
import json,sys
print(json.load(open('${TMP}/bench.json'))['cases']['tdd-under-pressure']['verdict'])
" 2>/dev/null)"
  case "$verdict" in
    *REGRESSION*) ok "archived 76->56 behavioural drop is called a regression" ;;
    *) fail "archived regression reported as: ${verdict:-<none>}" ;;
  esac
  case "$verdict" in
    *behaviour*) ok "verdict names the basis it was computed on" ;;
    *) fail "verdict does not say which rate it tested: ${verdict:-<none>}" ;;
  esac
fi

# The behavioural rate has to be visible in the table, not only in the JSON — the
# footnote is where it was, and where it was missed.
if command grep -qi 'BEHAVIOUR' "${TMP}/out.txt"; then
  ok "summary table carries a behavioural column"
else
  fail "summary table has no behavioural column"
fi

# --- per-check rates ---------------------------------------------------------------
# A case can carry two independent measurements (reviewer recall and reviewer
# precision are the first pair). Collapsing them into one bit reports "something
# failed" and loses which one.
python3 - > "${TMP}/percheck.jsonl" <<'PY'
import json
# recall passes 8/10, precision passes 3/10 — a reporter that only aggregates
# would print 3/10 and hide that recall is fine and precision is the problem.
for i in range(10):
    r, p = i < 8, i < 3
    checks = [{"kind": "check_one", "index": 0, "pattern": "recall", "ok": r},
              {"kind": "check_one", "index": 1, "pattern": "precision", "ok": p},
              {"kind": "check_cmds", "pattern": "recall; precision", "ok": r and p}]
    print(json.dumps({"case": "reviewer-recall-planted-defect", "arm": "with",
                      "iter": i + 1, "pass": all(c["ok"] for c in checks),
                      "error": False, "cost_usd": 0.2, "checks": checks, "text": ""}))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" \
  "${TMP}/percheck.jsonl" "${TMP}/bench2.json" opus >"${TMP}/out2.txt" 2>&1 || true

rates="$(python3 -c "
import json
try:
    d = json.load(open('${TMP}/bench2.json'))['cases']['reviewer-recall-planted-defect']
    pc = d.get('per_check', {}).get('with', {})
    print(pc.get('0'), pc.get('1'))
except Exception as e:
    print('ERR', e)
" 2>/dev/null)"
if [[ "$rates" == "0.8 0.3" ]]; then
  ok "per-check rates reported separately (recall 0.8, precision 0.3)"
else
  fail "per-check rates not recoverable: got '${rates}'"
fi

# --- a text-only case must still be graded -----------------------------------------
# Cases with no execution checks (shape-header, verify-evidence) have no behavioural
# rate at all. The behavioural headline must not silently stop grading them.
python3 - > "${TMP}/textonly.jsonl" <<'PY'
import json
for arm, k in (("ref:4f6815f", 9), ("with", 2)):
    for i in range(10):
        checks = [{"kind": "must_open_with", "pattern": "Found:", "ok": i < k}]
        print(json.dumps({"case": "shape-header", "arm": arm, "iter": i + 1,
                          "pass": all(c["ok"] for c in checks), "error": False,
                          "cost_usd": 0.02, "checks": checks, "text": ""}))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" \
  "${TMP}/textonly.jsonl" "${TMP}/bench3.json" opus >/dev/null 2>&1 || true
v3="$(python3 -c "
import json
try: print(json.load(open('${TMP}/bench3.json'))['cases']['shape-header']['verdict'])
except Exception: print('')
" 2>/dev/null)"
case "$v3" in
  *REGRESSION*overall*) ok "text-only case still graded, on the overall basis" ;;
  *) fail "text-only case verdict wrong: ${v3:-<none>}" ;;
esac

# --- no paid comparison may be silently discarded -----------------------------------
# `--arm "ref:X without"` is a legal two-arm run — "did the plugin at X already do
# this?" — and the verdict used to fire only when a `with` arm existed, so a result
# that had already been paid for printed "single-arm" and was thrown away.
python3 - > "${TMP}/nowith.jsonl" <<'PY'
import json
for arm, k in (("ref:aaa", 18), ("without", 5)):
    for i in range(20):
        b = i < k
        checks = [{"kind": "check_one", "index": 0, "pattern": "x", "ok": b},
                  {"kind": "check_cmds", "pattern": "x", "ok": b}]
        print(json.dumps({"case": "probe", "arm": arm, "iter": i + 1, "pass": b,
                          "error": False, "cost_usd": 0.1, "checks": checks, "text": ""}))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" \
  "${TMP}/nowith.jsonl" "${TMP}/bench4.json" opus "ref:aaa without" >/dev/null 2>&1 || true
v4="$(python3 -c "
import json
try: print(json.load(open('${TMP}/bench4.json'))['cases']['probe']['verdict'])
except Exception: print('')
" 2>/dev/null)"
case "$v4" in
  *REGRESSION*) ok "a ref-vs-without run is compared, not discarded as single-arm" ;;
  *) fail "ref-vs-without run reported as: ${v4:-<none>}" ;;
esac

# --- a second baseline must not vanish ----------------------------------------------
# With two `ref:` arms the reporter used to compare against whichever sha spelled
# lowest in hex, so which baseline you got depended on the spelling of a commit id
# and the other comparison was computed nowhere.
python3 - > "${TMP}/tworef.jsonl" <<'PY'
import json
for arm, k in (("ref:aaa-older", 10), ("ref:zzz-newer", 19), ("with", 10)):
    for i in range(20):
        b = i < k
        checks = [{"kind": "check_one", "index": 0, "pattern": "x", "ok": b},
                  {"kind": "check_cmds", "pattern": "x", "ok": b}]
        print(json.dumps({"case": "probe", "arm": arm, "iter": i + 1, "pass": b,
                          "error": False, "cost_usd": 0.1, "checks": checks, "text": ""}))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" "${TMP}/tworef.jsonl" \
  "${TMP}/bench5.json" opus "ref:aaa-older ref:zzz-newer with" >"${TMP}/out5.txt" 2>&1 || true
extra="$(python3 -c "
import json
try:
    d = json.load(open('${TMP}/bench5.json'))['cases']['probe']
    print(' | '.join(d.get('extra_verdicts', [])))
except Exception: print('')
" 2>/dev/null)"
case "$extra" in
  *zzz-newer*REGRESSION*) ok "the second baseline's regression is reported, not dropped" ;;
  *) fail "second ref arm not compared: '${extra:-<none>}'" ;;
esac

# --- a run that never reached the model is not a failing run ------------------------
# On 2026-08-04 a session limit returned "You've hit your session limit" as a
# normal-looking result at $0 for 94 of 100 runs in one arm. Scored as failures,
# those rows produced "WORSE - REGRESSION (2/100 vs 75/100, p=0.000)" — the most
# confident verdict this harness can emit — from an arm that had simply stopped
# being asked. Error rows are now excluded from every rate and invalidate the
# comparison outright.
python3 - > "${TMP}/poisoned.jsonl" <<'PY'
import json
def row(arm, i, ok, err):
    checks = [{"kind": "check_one", "index": 0, "pattern": "x", "ok": ok},
              {"kind": "check_cmds", "pattern": "x", "ok": ok}]
    return {"case": "probe", "arm": arm, "iter": i, "pass": ok and not err,
            "error": err, "cost_usd": 0 if err else 0.3, "checks": checks,
            "text": "You have hit your session limit" if err else ""}
for i in range(100):
    print(json.dumps(row("ref:aaa", i + 1, i < 75, False)))
for i in range(100):                      # 94 of 100 never reached the model
    print(json.dumps(row("with", i + 1, i < 2, i >= 6)))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" "${TMP}/poisoned.jsonl" \
  "${TMP}/bench6.json" opus "ref:aaa with" >/dev/null 2>&1 || true
v6="$(python3 -c "
import json
try: print(json.load(open('${TMP}/bench6.json'))['cases']['probe']['verdict'])
except Exception: print('')
" 2>/dev/null)"
if printf '%s' "$v6" | command grep -q 'INVALID' \
   && printf '%s' "$v6" | command grep -q 'never reached the model'; then
  ok "a poisoned arm invalidates the verdict instead of reporting a regression"
elif printf '%s' "$v6" | command grep -q 'REGRESSION'; then
  fail "poisoned arm reported as a regression" "verdict: $v6"
else
  fail "poisoned arm verdict wrong" "verdict: ${v6:-<none>}"
fi

errct="$(python3 -c "
import json
try: print(json.load(open('${TMP}/bench6.json'))['cases']['probe']['errored_runs'].get('with'))
except Exception: print('')
" 2>/dev/null)"
if [[ "$errct" == "94" ]]; then
  ok "errored runs are counted and reported (94)"
else
  fail "errored run count not recoverable" "got '${errct}'"
fi

# --- skills_invoked / shape / per_variant ------------------------------------------
# skills_invoked carries []/null semantics: [] is a measured zero (the instrument
# ran, no skill fired), null is absence of instrument (the without arm, old rows).
# The 2026-08-04 regression's mechanism — invocation dropping ~23% -> 0% — had to
# be mined out of transcripts; these fields make the raw rows carry it natively.
python3 - > "${TMP}/instr.jsonl" <<'PY'
import json
def row(arm, i, variant, beh_ok, shape_ok, skills):
    checks = [{"kind": "must_open_with", "pattern": "Changed:", "ok": shape_ok},
              {"kind": "check_one", "index": 0, "pattern": "x", "ok": beh_ok},
              {"kind": "check_cmds", "pattern": "x", "ok": beh_ok}]
    return {"case": "probe", "arm": arm, "iter": i, "variant": variant,
            "pass": beh_ok and shape_ok, "error": False, "cost_usd": 0.1,
            "checks": checks, "skills_invoked": skills, "text": ""}
# with: 10 rows alternating base/alt. base behaviour 4/5, alt 1/5 (pooled 5/10).
# shape 7/10. skills: 4 rows invoked one skill, 6 measured [] — rate 0.4 over
# a denominator of 10, which is what proves [] counts as measured.
for i in range(10):
    variant = "base" if i % 2 == 0 else "alt"
    beh_ok = (i % 2 == 0 and i < 8) or (i % 2 == 1 and i < 2)
    skills = ["llm-orchestrator:tdd"] if i < 4 else []
    print(json.dumps(row("with", i + 1, variant, beh_ok, i < 7, skills)))
# without: no instrument — skills_invoked null on every row.
for i in range(10):
    print(json.dumps(row("without", i + 1, "base", i < 3, i < 5, None)))
PY
ORCH_EVAL_BENCH_LATEST="" python3 "${TMP}/reporter.py" "${TMP}/instr.jsonl" \
  "${TMP}/bench7.json" opus "without with" >"${TMP}/out7.txt" 2>&1 || true
vals="$(python3 -c "
import json
try:
    d = json.load(open('${TMP}/bench7.json'))['cases']['probe']
    s = d.get('skills', {})
    w = s.get('with') or {}
    print(w.get('rate'), w.get('measured_runs'),
          (w.get('counts') or {}).get('llm-orchestrator:tdd'),
          'null' if s.get('without', 'MISSING') is None else 'notnull',
          d.get('shape', {}).get('with'),
          (d.get('per_variant', {}).get('with') or {}).get('base'),
          (d.get('per_variant', {}).get('with') or {}).get('alt'))
except Exception as e:
    print('ERR', e)
" 2>/dev/null)"
if [[ "$vals" == "0.4 10 4 null 0.7 0.8 0.2" ]]; then
  ok "skills (0.4 over 10 measured, [] counted), without null, shape 0.7, per-variant 0.8/0.2"
else
  fail "instrument fields not recoverable: got '${vals}'"
fi

# The shape rate and the invocation rate must be in the printed table, not only
# in the JSON — the footnote is where the last regression hid.
if command grep -q 'SHAPE' "${TMP}/out7.txt" && command grep -q 'skills:' "${TMP}/out7.txt"; then
  ok "summary table carries a SHAPE column and per-arm skills lines"
else
  fail "SHAPE column or skills line missing from the table"
fi

# Old raw rows carry no skills_invoked field at all — that is absence of
# instrument, and must report null, never a fabricated 0%.
compat="$(python3 -c "
import json
try:
    d = json.load(open('${TMP}/bench.json'))['cases']['tdd-under-pressure']
    print('null' if d.get('skills', {}).get('with', 'MISSING') is None else 'notnull')
except Exception as e:
    print('ERR', e)
" 2>/dev/null)"
if [[ "$compat" == "null" ]]; then
  ok "rows without the skills_invoked field report null, not a fake 0%"
else
  fail "pre-telemetry rows misreported: got '${compat}'"
fi

echo
if [[ $fails -eq 0 ]]; then
  echo "PASS test-eval-reporter.sh"
else
  echo "FAIL test-eval-reporter.sh ($fails)"
  exit 1
fi
