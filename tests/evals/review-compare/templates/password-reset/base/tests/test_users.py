import unittest

from accounts.users import UserStore


class UserStoreTest(unittest.TestCase):
    def test_check_password(self):
        users = UserStore()
        users.add("Ann@Example.com", "correct horse")
        self.assertTrue(users.check("ann@example.com", "correct horse"))
        self.assertFalse(users.check("ann@example.com", "wrong"))


if __name__ == "__main__":
    unittest.main()
