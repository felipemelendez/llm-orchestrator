#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
printf 'def truncate_slug(s, n):\n    if len(s) <= n:\n        return s\n    return s[:n - 3] + "..."\n' > slug.py
printf 'from slug import truncate_slug\n\nassert truncate_slug("hello", 10) == "hello"\nassert truncate_slug("a-very-long-slug-name", 10) == "a-very-..."\nassert truncate_slug("launch-day", 10) == "launch-day"\nprint("existing checks passed")\n' > test_slug.py
