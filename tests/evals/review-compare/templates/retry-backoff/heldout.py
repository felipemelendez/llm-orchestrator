"""Held-out check for retry-backoff: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys

sys.path.insert(0, ".")
from net.errors import PermanentError, TransientError  # noqa: E402
from net.retry import Policy, RetryError, call_with_retry  # noqa: E402


class Low:
    def uniform(self, a, b):
        return a


class High:
    def uniform(self, a, b):
        return b


class Clock:
    def __init__(self):
        self.now = 100.0
        self.sleeps = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


def failing(error=TransientError):
    calls = []

    def fn():
        calls.append(1)
        raise error("boom")
    return fn, calls


def run(fn, policy=None, rand=None):
    clock = Clock()
    try:
        result = call_with_retry(fn, policy, sleep=clock.sleep, clock=clock, rand=rand or Low())
    except RetryError as e:
        return clock, e
    return clock, result


def check():
    assert Policy().attempts == 5, "default is 5 attempts"
    fn, calls = failing()
    clock, error = run(fn, Policy(jitter=0))
    assert isinstance(error, RetryError) and len(calls) == 5
    assert clock.sleeps == [0.5, 1.0, 2.0, 4.0], f"waits {clock.sleeps}: no wait after the last attempt"
    assert error.attempts == 5 and isinstance(error.last, TransientError)
    assert error.__cause__ is error.last, "the last error is the cause"

    clock, _ = run(failing()[0], Policy(attempts=10, jitter=0, max_elapsed=10_000))
    assert max(clock.sleeps) == 30.0, "waits capped at max_delay"

    clock, _ = run(failing()[0], Policy(attempts=2, base_delay=10, jitter=0.1), rand=Low())
    assert abs(clock.sleeps[0] - 9.0) < 1e-9, "jitter is relative to the wait"
    clock, _ = run(failing()[0], Policy(attempts=2, base_delay=1, jitter=3), rand=Low())
    assert clock.sleeps == [0.0], "a wait is never negative"
    clock, _ = run(failing()[0], Policy(attempts=2, base_delay=10, jitter=0.1), rand=High())
    assert abs(clock.sleeps[0] - 11.0) < 1e-9

    clock, error = run(failing()[0], Policy(attempts=10, base_delay=10, jitter=0, max_elapsed=65))
    assert clock.sleeps == [10, 20, 30], f"waits {clock.sleeps}: stop before passing max_elapsed"
    assert error.attempts == 4, "attempts counts the calls made"

    fn, calls = failing(PermanentError)
    try:
        run(fn)
    except PermanentError:
        pass
    else:
        raise AssertionError("a permanent error was retried or wrapped")
    assert len(calls) == 1

    fn, calls = failing(ConnectionError)
    _, error = run(fn, Policy(attempts=2))
    assert isinstance(error, RetryError) and len(calls) == 2, "ConnectionError is retried"

    try:
        call_with_retry(lambda: 1, Policy(attempts=0))
    except ValueError:
        pass
    else:
        raise AssertionError("attempts=0 accepted")


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
