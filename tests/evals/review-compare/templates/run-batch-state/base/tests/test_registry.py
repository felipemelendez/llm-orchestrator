import unittest

from jobs.registry import Registry, UnknownJob


class RegistryTest(unittest.TestCase):
    def test_register_and_get(self):
        registry = Registry()
        handler = lambda options: "ok"
        registry.register("resize", handler, {"retries": 1})
        self.assertEqual(registry.get("resize"), (handler, {"retries": 1}))
        self.assertEqual(registry.defaults("resize"), {"retries": 1})

    def test_defaults_are_optional(self):
        registry = Registry()
        registry.register("ping", lambda options: None)
        self.assertEqual(registry.defaults("ping"), {})

    def test_unknown_name(self):
        with self.assertRaises(UnknownJob):
            Registry().get("missing")

    def test_names_sorted(self):
        registry = Registry()
        registry.register("b", print)
        registry.register("a", print)
        self.assertEqual(registry.names(), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
