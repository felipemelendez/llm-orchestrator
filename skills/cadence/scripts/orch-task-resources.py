#!/usr/bin/env python3
"""Locate the single shared task-resource helper in source or copied skills."""
from pathlib import Path
import runpy
import sys

here = Path(__file__).resolve()
helper = here.parents[3] / "scripts/lib/orch-task-resources.py"
if not helper.is_file():
    sys.exit("Task-resource helper missing; reinstall the cadence skill.")
runpy.run_path(str(helper), run_name="__main__")
