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

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
[[ -f "$RUNNER" ]] || { echo "FAIL: $RUNNER missing"; exit 1; }

echo "== eval reporter =="

# The reporter is the heredoc'd python block at the end of the runner. Extract it
# rather than re-implementing it, so this test cannot drift from what ships.
python3 - "$RUNNER" > "${TMP}/reporter.py" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"python3 - \"\$RESULTS\" \"\$BENCH\" \"\$MODEL\" <<'PY'\n(.*?)\nPY\n", src, re.S)
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

echo
if [[ $fails -eq 0 ]]; then
  echo "PASS test-eval-reporter.sh"
else
  echo "FAIL test-eval-reporter.sh ($fails)"
  exit 1
fi
