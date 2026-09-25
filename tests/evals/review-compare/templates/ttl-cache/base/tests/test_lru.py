import unittest

from cache.lru import LRUCache


class LRUCacheTest(unittest.TestCase):
    def test_get_returns_stored_value(self):
        cache = LRUCache()
        cache.set("a", 1)
        self.assertEqual(cache.get("a"), 1)
        self.assertIsNone(cache.get("missing"))

    def test_oldest_entry_is_evicted(self):
        cache = LRUCache(max_size=2)
        cache.set("a", 1)
        cache.set("b", 2)
        cache.set("c", 3)
        self.assertIsNone(cache.get("a"))
        self.assertEqual(len(cache), 2)


if __name__ == "__main__":
    unittest.main()
