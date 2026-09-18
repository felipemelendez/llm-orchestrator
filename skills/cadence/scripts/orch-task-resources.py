#!/usr/bin/env python3
"""Locate the single shared task-resource helper in source or copied skills."""
from pathlib import Path
import runpy
import sys

here = Path(__file__).resolve()
candidates = (
    here.parent / "lib/orch-task-resources.py",
    here.parents[3] / "scripts/lib/orch-task-resources.py",
)
for candidate in candidates:
    if candidate.is_file():
        runpy.run_path(str(candidate), run_name="__main__")
        break
else:
    sys.exit("Task-resource helper missing; reinstall the cadence skill.")
