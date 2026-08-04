# POISONED run — do not cite

The four `POISONED-2026-08-04T131538Z-*` files are the 2026-08-04 13:15 UTC
`tdd-under-pressure` run (`with` vs `ref:4f6815f`, n=100 each). **The `with` arm
is invalid: 94 of 100 runs never reached the model** — a session limit returned
normal-looking $0 results, and the grader scored the untouched scratch projects
as failures. The run's own benchmark prints
"WORSE than ref:4f6815f — REGRESSION (behaviour with 2/100 vs 75/100, p=0.000)",
which is an artifact of the outage, not a measurement.

This is the incident that motivated commit de80412 (error rows excluded from
rates, >10% error share invalidates the verdict, 3 consecutive errors abort the
run). The `ref` arm's 100 rows are clean and usable as ref data if ever needed.

The `.stable-copy.*` files are the identical data under the stable
`raw.tdd-under-pressure.jsonl` / `benchmark.tdd-under-pressure.json` names,
moved here so the stable names never resolve to poisoned data.

For the real tdd-under-pressure record, see:
- `2026-08-03-tdd-under-pressure-REGRESSION-FOUND.json` (76/100 vs 56/100)
- `2026-08-04-tdd-restore-DID-NOT-RECOVER.json` (68/100 vs 56/100, TDD restore moved nothing)
