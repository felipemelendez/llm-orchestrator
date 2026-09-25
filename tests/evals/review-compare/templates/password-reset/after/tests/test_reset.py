import itertools
import unittest
from datetime import datetime

from accounts.reset import ResetError, ResetService
from accounts.users import UserStore


class Clock:
    def __init__(self):
        self.now = datetime(2026, 5, 1, 9, 0)

    def __call__(self):
        return self.now


class ResetTest(unittest.TestCase):
    def setUp(self):
        self.users = UserStore()
        self.users.add("ann@example.com", "old password 1")
        self.clock = Clock()
        counter = itertools.count(1)
        self.service = ResetService(self.users, self.clock, new_token=lambda: f"token-{next(counter)}")

    def test_redeem_sets_password(self):
        token = self.service.request("ann@example.com")
        self.assertEqual(self.service.redeem(token, "a new long password"), "ann@example.com")
        self.assertTrue(self.users.check("ann@example.com", "a new long password"))

    def test_unknown_user(self):
        self.assertIsNone(self.service.request("bob@example.com"))

    def test_unknown_token(self):
        with self.assertRaises(ResetError):
            self.service.redeem("not-a-token", "a new long password")

    def test_rejects_short_password(self):
        token = self.service.request("ann@example.com")
        with self.assertRaises(ResetError):
            self.service.redeem(token, "x" * 11)


if __name__ == "__main__":
    unittest.main()
