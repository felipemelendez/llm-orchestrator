#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
mkdir -p docs/llm-orchestrator/handoffs
cat > docs/llm-orchestrator/handoffs/2026-09-25-text-utils.md <<'MD'
# Handoff: text utilities

- Done: slugify, covered by test_text_utils.py.
- Remaining: truncate_words (still raises NotImplementedError).
- Verify first: python3 test_text_utils.py
MD
