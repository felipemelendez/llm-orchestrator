#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
mkdir -p docs/llm-orchestrator/plans
cat > docs/llm-orchestrator/plans/2026-09-25-csv-export-plan.md <<'MD'
# CSV export helpers -- Plan

### 1. escape_field  - [ ]
- run: `python3 test_csv_export.py`
Done when: `python3 test_csv_export.py` passes the escape_field cases.

### 2. format_row  - [ ]
- run: `python3 test_csv_export.py`
Done when: `python3 test_csv_export.py` passes the format_row cases.

### 3. export_rows  - [ ]
- run: `python3 test_csv_export.py`
Done when: `python3 test_csv_export.py` passes the export_rows cases.
MD
