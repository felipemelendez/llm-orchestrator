# Retry calls to flaky services

`call_with_retry(fn, policy=None, sleep=time.sleep, clock=time.monotonic,
rand=None)` calls `fn()` until it returns, and returns its result.

- `Policy` defaults: 5 attempts, base delay 0.5 s, max delay 30 s, max
  elapsed 120 s, jitter 0.1. `attempts` below 1 is a `ValueError`.
- Only exceptions in `policy.retry_on` (by default `TransientError`,
  `TimeoutError` and `ConnectionError`) are retried. Any other exception
  propagates at once, unchanged.
- The wait after failed attempt `n` (1-based) is `base_delay * 2 ** (n - 1)`,
  capped at `max_delay`, then moved by a random amount of at most
  `jitter` times that value in either direction. It is never negative.
- There is no wait after the last attempt.
- Before waiting, if the time since the first call plus the wait would pass
  `max_elapsed`, stop retrying.
- When retrying stops, raise `RetryError` with `attempts` set to the number of
  calls made and `last` set to the last exception, which is also its
  `__cause__`.
