import unittest

from names.registry import Registry


class RegistryTest(unittest.TestCase):
    def test_add_and_get(self):
        registry = Registry()
        registry.add("alice", "Alice Smith")
        self.assertEqual(registry.get("alice")["display_name"], "Alice Smith")
        self.assertIsNone(registry.get("bob"))


if __name__ == "__main__":
    unittest.main()
