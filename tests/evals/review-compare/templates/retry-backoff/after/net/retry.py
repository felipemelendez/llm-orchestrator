"""Retry calls to flaky services."""
import random
import time
from dataclasses import dataclass

from net.errors import TransientError


class RetryError(Exception):
    """Every attempt failed; `last` is the final exception."""

    def __init__(self, attempts, last):
        super().__init__(f"gave up after {attempts} attempts: {last!r}")
        self.attempts = attempts
        self.last = last


@dataclass
class Policy:
    attempts: int = 5
    base_delay: float = 0.5
    max_delay: float = 30.0
    max_elapsed: float = 120.0
    jitter: float = 0.1
    retry_on: tuple = (TransientError, TimeoutError, ConnectionError)

    def delay(self, attempt, rand):
        """Seconds to wait after failed attempt number `attempt` (1-based)."""
        raw = min(self.base_delay * 2 ** (attempt - 1), self.max_delay)
        spread = raw * self.jitter
        return max(0.0, raw + rand.uniform(-spread, spread))


def call_with_retry(fn, policy=None, sleep=time.sleep, clock=time.monotonic, rand=None):
    policy = policy or Policy()
    if policy.attempts < 1:
        raise ValueError("attempts must be at least 1")
    rand = rand or random.Random()
    started = clock()
    for attempt in range(1, policy.attempts + 1):
        try:
            return fn()
        except policy.retry_on as error:
            last = error
        if attempt == policy.attempts:
            break
        wait = policy.delay(attempt, rand)
        if clock() - started + wait > policy.max_elapsed:
            break
        sleep(wait)
    raise RetryError(attempt, last) from last
