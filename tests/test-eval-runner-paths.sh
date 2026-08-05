#!/usr/bin/env bash
# The eval runner embeds arm names in scratch paths. Arm names are labels and
# may contain characters that are not path-safe — "ref:exp/compression-mandate-kept"
# carries a slash, which turned the scratch filename into a nonexistent
# subdirectory and aborted the 2026-08-05 compression A/B after its first arm
# had already been paid for. This suite drives the WORKING-TREE runner
# end-to-end in ORCH_EVAL_DRY_RUN mode (no model call, no cost) with a
# slash-bearing ref arm — "ref:refs/heads/main", a spelling every clone can
# resolve — and requires: exit 0, a graded row, the ORIGINAL arm string as the
# row label, and a sanitized on-disk scratch name.
#
# It also pins the dry-run mode's own hygiene:
#   - a dry run must not touch the stable-name result copies (raw.<case>.jsonl
#     / benchmark.<case>.json) that real consumers resolve;
#   - every dry-run row must carry dry_run:true, so a stray row can never
#     masquerade as measured data;
#   - dry-run must not require the claude CLI — it never calls it, and on a
#     claude-less machine the suite used to FAIL rather than run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

skip_suite() {
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    echo "FAIL: test-eval-runner-paths — $1 (ORCH_REQUIRE_DEPS=1)"; exit 1
  fi
  echo "SKIP: test-eval-runner-paths ($1)"; exit 0
}
command -v python3 >/dev/null 2>&1 || skip_suite 'python3 not found'
command -v git >/dev/null 2>&1 || skip_suite 'git not found'
git -C "$ROOT" rev-parse refs/heads/main >/dev/null 2>&1 || skip_suite 'no local main branch'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0; oks=0
ok()   { printf '  ok   %s\n' "$1"; oks=$((oks + 1)); }
fail() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "== eval runner: slash-bearing arm names, dry-run hygiene =="

RUN_ID="dryrun-paths-test"
RUN_ID2="dryrun-noclaude-test"
OUT="$ROOT/tests/evals/results"
STABLE_FILES="raw.shape-header.jsonl benchmark.shape-header.json"
# A dry run must leave the stable-name copies exactly as it found them. Record
# each file's pre-run state: bytes if it existed, absence if it did not — on
# restore, a file that had NO backup was CREATED by the run under test and is
# pollution, so it is removed rather than left behind.
for f in $STABLE_FILES; do
  if [[ -f "$OUT/$f" ]]; then cp "$OUT/$f" "$TMP/backup.$f"; fi
done
restore() {
  for f in $STABLE_FILES; do
    if [[ -f "$TMP/backup.$f" ]]; then cp "$TMP/backup.$f" "$OUT/$f"
    else rm -f "$OUT/$f"; fi
  done
  rm -f "$OUT/raw.shape-header.${RUN_ID}.jsonl" "$OUT/benchmark.shape-header.${RUN_ID}.json"
  rm -f "$OUT/raw.shape-header.${RUN_ID2}.jsonl" "$OUT/benchmark.shape-header.${RUN_ID2}.json"
  rm -rf "$TMP"
}
trap 'restore' EXIT

set +e
TMPDIR="$TMP/scratch/" ORCH_EVAL_DRY_RUN=1 ORCH_EVAL_RUN_ID="$RUN_ID" \
  bash "$ROOT/tests/evals/run-evals.sh" \
  --case shape-header --arm "ref:refs/heads/main" --n 1 --model opus \
  >"$TMP/run.log" 2>&1
rc=$?
set -e

if [[ $rc -eq 0 ]]; then ok "runner exits 0 with a slash-bearing ref arm"
else fail "runner exits 0 with a slash-bearing ref arm (rc=$rc; tail: $(tail -2 "$TMP/run.log" | tr '\n' ' '))"; fi

RAW="$OUT/raw.shape-header.${RUN_ID}.jsonl"
if [[ -s "$RAW" ]]; then ok "raw row written"
else fail "raw row written ($RAW missing/empty)"; fi

if [[ -s "$RAW" ]] && python3 - "$RAW" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).readline())
assert r["arm"] == "ref:refs/heads/main", r["arm"]
assert r.get("error") is False, "dry-run row must not be an error row"
PY
then ok "row keeps the ORIGINAL arm label and is not an error row"
else fail "row keeps the ORIGINAL arm label and is not an error row"; fi

if ls "$TMP/scratch/llm-orch-evals"/shape-header-ref_refs_heads_main-1 >/dev/null 2>&1; then
  ok "scratch dir name is sanitized (no path separators from the arm)"
else
  fail "scratch dir name is sanitized (found: $(ls "$TMP/scratch/llm-orch-evals" 2>/dev/null | head -3 | tr '\n' ' '))"
fi

# --- dry-run pollution: the stable-name copies are measured data, not scratch ---
# Each stable file must match its pre-run state exactly: same bytes if it
# existed, still absent if it did not. A dry run that overwrites (or mints)
# them replaces the newest REAL run's copy with unmeasured plumbing output.
for f in $STABLE_FILES; do
  if [[ -f "$TMP/backup.$f" ]]; then
    if cmp -s "$OUT/$f" "$TMP/backup.$f"; then ok "stable $f untouched by dry-run"
    else fail "stable $f untouched by dry-run (bytes differ from the pre-run copy)"; fi
  else
    if [[ ! -f "$OUT/$f" ]]; then ok "stable $f not created by dry-run"
    else fail "stable $f not created by dry-run (dry-run minted a stable copy)"; fi
  fi
done

# --- dry-run rows self-identify, so a stray row can never pass as measured data ---
if [[ -s "$RAW" ]] && python3 - "$RAW" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).readline())
assert r.get("dry_run") is True, "row lacks dry_run:true (got %r)" % (r.get("dry_run"),)
PY
then ok "dry-run row carries dry_run:true"
else fail "dry-run row carries dry_run:true"; fi

# --- dry-run must not require the claude CLI (it never calls it) ---
# Simulate a claude-less machine: strip every PATH dir that holds an
# executable `claude`. Only meaningful if the stripped PATH still resolves the
# runner's real dependencies and no longer resolves claude.
NOCLAUDE_PATH="$(python3 - <<'PY'
import os
dirs = []
for d in os.environ.get("PATH", "").split(os.pathsep):
    p = os.path.join(d, "claude")
    if os.path.isfile(p) and os.access(p, os.X_OK):
        continue
    dirs.append(d)
print(os.pathsep.join(dirs))
PY
)"
if env PATH="$NOCLAUDE_PATH" bash -c 'command -v claude' >/dev/null 2>&1; then
  echo "  skip claude-less check (claude shares a PATH dir with other tools here)"
elif ! env PATH="$NOCLAUDE_PATH" bash -c 'command -v python3 >/dev/null && command -v git >/dev/null'; then
  echo "  skip claude-less check (stripping claude also stripped python3/git)"
else
  set +e
  TMPDIR="$TMP/scratch2/" PATH="$NOCLAUDE_PATH" ORCH_EVAL_DRY_RUN=1 ORCH_EVAL_RUN_ID="$RUN_ID2" \
    bash "$ROOT/tests/evals/run-evals.sh" \
    --case shape-header --arm "ref:refs/heads/main" --n 1 --model opus \
    >"$TMP/run2.log" 2>&1
  rc2=$?
  set -e
  if [[ $rc2 -eq 0 ]]; then ok "dry-run exits 0 with no claude CLI on PATH"
  else fail "dry-run exits 0 with no claude CLI on PATH (rc=$rc2; tail: $(tail -2 "$TMP/run2.log" | tr '\n' ' '))"; fi
fi

if [[ $fails -eq 0 ]]; then echo "PASS: test-eval-runner-paths ($oks checks)"; exit 0
else echo "FAIL: test-eval-runner-paths — $fails failed"; exit 1; fi
