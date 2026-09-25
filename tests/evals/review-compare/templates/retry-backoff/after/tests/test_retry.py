import random
import unittest

from net.errors import TransientError
from net.retry import Policy, RetryError, call_with_retry


class Flaky:
    def __init__(self, failures):
        self.failures = failures
        self.calls = 0

    def __call__(self):
        self.calls += 1
        if self.calls <= self.failures:
            raise TransientError("503")
        return "ok"


class RetryTest(unittest.TestCase):
    def setUp(self):
        self.sleeps = []

    def call(self, fn, policy=None):
        return call_with_retry(fn, policy, sleep=self.sleeps.append, clock=lambda: 0.0,
                               rand=random.Random(0))

    def test_succeeds_after_transient_failures(self):
        fn = Flaky(2)
        self.assertEqual(self.call(fn), "ok")
        self.assertEqual(fn.calls, 3)
        self.assertEqual(len(self.sleeps), 2)

    def test_gives_up(self):
        fn = Flaky(100)
        with self.assertRaises(RetryError):
            self.call(fn)
        self.assertEqual(fn.calls, 5, "gave up too early")

    def test_delay_grows(self):
        policy = Policy(jitter=0)
        self.assertLess(policy.delay(1, random.Random(0)), policy.delay(2, random.Random(0)))


if __name__ == "__main__":
    unittest.main()
