#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
write() { printf 'def run(value):\n    return %s\n' "$2" > "plugins/$1.py"; }
write double 'value * 2'
write square 'value ** 2'
write negate '-value'
write increment 'value + 1'
write halve 'value / 2'
write triple 'value * 3'
write decrement 'value - 1'
write cube 'value ** 3'
python3 - <<'PY'
import json
names = ["cube", "decrement", "double", "halve", "identity", "increment", "negate", "square", "stringify", "triple"]
plugins = {n: n + ".py" for n in names}
open("plugins/manifest.json", "w").write(json.dumps({"plugins": plugins}, indent=2, sort_keys=True) + "\n")
PY
python3 test_loader.py >/dev/null
