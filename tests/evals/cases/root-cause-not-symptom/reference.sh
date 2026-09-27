#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
python3 - <<'PY'
import pathlib
p = pathlib.Path("config.py")
t = p.read_text()
t = t.replace('"""\n\n\ndef _split_pairs', '"""\n\nimport re\n\n\ndef _split_pairs', 1)
t = t.replace('return [p for p in text.split(";") if p]', 'return [p for p in re.split(r"[;\\n]", text) if p]')
p.write_text(t)
PY
