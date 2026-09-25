Changed: freshness.py — an entry on its last TTL day is no longer expired; test_freshness.py asserts is_expired(30, 30) is False.

Verification: PASS — `python3 test_freshness.py` printed "existing checks passed".
