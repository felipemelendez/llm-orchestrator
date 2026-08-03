#!/usr/bin/env bash
# LLM Orchestrator workflow-script validator.
#
# Workflow scripts (workflows/*.js) run inside Claude Code's Workflow engine, which
# imposes constraints that a syntax-only parse cannot fully enforce. This validator
# runs TWO layers, because `node --check` is necessary but NOT sufficient:
#
#   Layer A — node --check: catches syntax errors and most TypeScript annotations.
#   Layer B — static token scan: catches constructs that are parse-valid JS but
#             throw (or are banned) at runtime — the nondeterministic time/random
#             builtins and module imports. `node --check` exits 0 on these, so a
#             grep scan is required. (Confirmed: a file containing Date.now /
#             Math.random / import passes `node --check`.)
#
# Also enforces project-specific invariants:
#   - meta must be a pure literal (script begins with `export const meta`).
#   - No security-regex duplication: the security-sensitive token set lives ONLY in
#     scripts/lib/orch-signals.sh and is passed into workflows via args. A workflow
#     must contain no `auth|crypt...` alternation literal (single source of truth).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/workflows"
fail=0
checked=0

if [[ ! -d "$DIR" ]]; then
  echo "OK: no workflows/ directory — nothing to validate"
  exit 0
fi

have_node=1
command -v node >/dev/null 2>&1 || { have_node=0; echo "WARN: node not found — skipping Layer A (node --check); Layer B still runs" >&2; }

TMPDIR_VW="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_VW"' EXIT
SCRIPT_CHECKER="$ROOT/tests/lib/check-workflow-script.mjs"
if (( have_node )) && [[ ! -f "$SCRIPT_CHECKER" ]]; then
  echo "FAIL: script checker missing: $SCRIPT_CHECKER"
  exit 1
fi

while IFS= read -r file; do
  rel="${file#$ROOT/}"

  # The script must OPEN with the meta literal (pure-literal contract).
  first=$(grep -vE '^[[:space:]]*(//|$)' "$file" | head -1)
  case "$first" in
    "export const meta"[[:space:]]*=*|"export const meta="*) : ;;
    *)
      echo "FAIL: $rel — must begin with 'export const meta = {...}' (got: ${first:0:40})"
      fail=1
      continue ;;
  esac

  # Layer A — real syntax check + meta-shape validation.
  #
  # `node --check <file.js>` could never reject anything here: a .js file
  # containing `export` is parsed as ESM, where node --check returns 0 on
  # invalid syntax — and this validator REQUIRES `export const meta`. Measured
  # on node v24.10.0: garbage alone -> rc=1; the same garbage below an
  # `export` line -> rc=0. "OK: N workflow script(s) validated" was therefore
  # never evidence of syntactic validity.
  #
  # The checker compiles the script as an ASYNC FUNCTION BODY, which is the
  # grammar the Workflow engine runs — top-level `return` and `await` are
  # legal there and illegal in a module, so a .mjs copy would reject our own
  # valid script. Compiled, never invoked.
  if (( have_node )); then
    if ! script_err=$(node "$SCRIPT_CHECKER" "$file" 2>&1); then
      echo "FAIL: $rel — $script_err"
      fail=1
    fi
  fi

  # Layer B — banned runtime-throw builtins + imports (parse-valid; node --check misses these)
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    if grep -nE "$pat" "$file" >/dev/null 2>&1; then
      echo "FAIL: $rel — banned construct matched /$pat/ (throws at runtime in the Workflow engine)"
      grep -nE "$pat" "$file" | sed 's/^/    /' >&2
      fail=1
    fi
  done <<'PATS'
Date\.now
Math\.random
performance\.now
new[[:space:]]+Date
^[[:space:]]*import[[:space:]]
\brequire[[:space:]]*\(
PATS

  # Single-source-of-truth: no security regex alternation inside a workflow.
  if grep -nE 'auth\|crypt|crypt\|payment' "$file" >/dev/null 2>&1; then
    echo "FAIL: $rel — contains a security-token regex; that set lives only in scripts/lib/orch-signals.sh and must arrive via args"
    fail=1
  fi

  checked=$((checked+1))
done < <(find "$DIR" -maxdepth 1 -name '*.js' | sort)

# A directory that exists but holds nothing is not a pass. `workflows/` is named
# by requesting-code-review and commands/review.md; an empty one means those
# instructions point at nothing, which is the failure this validator exists for.
# The message states the actual scope scanned: only the TOP LEVEL of workflows/
# is searched (maxdepth 1), because only top-level files are workflow entry
# points — a nested workflows/sub/x.js does not make this a false claim.
if (( checked == 0 )); then
  echo "FAIL: no *.js at the top level of $DIR — skills reference workflows/review-diff.js (nested files are not workflow entry points)"
  exit 1
fi

if (( fail == 0 )); then
  if (( have_node )); then
    echo "OK: $checked workflow script(s) validated"
  else
    # Layer A did not run, so this was not a full validation and must not
    # print the full-validation pass line — callers (smoke.sh) key off the
    # wording and would otherwise book a half-run as a full pass.
    echo "OK (degraded): $checked workflow script(s) scanned — node missing, Layer A (node --check) skipped"
  fi
else
  echo "FAILED"
  exit 1
fi
