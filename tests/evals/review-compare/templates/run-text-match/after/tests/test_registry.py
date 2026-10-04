import unittest

from names.registry import BadUsername, Registry, Taken
from names.text import BadTag


class RegistryTest(unittest.TestCase):
    def test_add_and_get(self):
        registry = Registry()
        registry.add("alice", "Alice Smith")
        self.assertEqual(registry.get("alice")["display_name"], "Alice Smith")
        self.assertIsNone(registry.get("bob"))

    def test_bad_and_reserved_usernames(self):
        registry = Registry()
        for name in ("al", "admin", "Root"):
            with self.assertRaises(BadUsername):
                registry.add(name, f"Person {name}")

    def test_username_taken_any_case(self):
        registry = Registry()
        registry.add("alice", "Alice Smith")
        with self.assertRaises(Taken):
            registry.add("Alice", "Another Alice")

    def test_display_name_taken(self):
        registry = Registry()
        registry.add("alice", "Ann Lee")
        with self.assertRaises(Taken):
            registry.add("bob", "ann  LEE")

    def test_set_tags(self):
        registry = Registry()
        registry.add("alice", "Alice Smith")
        self.assertEqual(registry.set_tags("alice", "Go, #news"), ["go", "news"])
        with self.assertRaises(BadTag):
            registry.set_tags("alice", "go, c++")
        self.assertEqual(registry.get("alice")["tags"], ["go", "news"])


if __name__ == "__main__":
    unittest.main()
