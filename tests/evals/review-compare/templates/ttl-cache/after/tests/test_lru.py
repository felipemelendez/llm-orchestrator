import unittest

from cache.lru import LRUCache


class FakeClock:
    def __init__(self, now=0.0):
        self.now = now

    def __call__(self):
        return self.now


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

    def test_rejects_non_positive_size(self):
        with self.assertRaises(ValueError):
            LRUCache(max_size=0)


class ExpiryTest(unittest.TestCase):
    def test_entry_expires_after_ttl(self):
        clock = FakeClock(100)
        cache = LRUCache(clock=clock)
        cache.set("a", 1, ttl=10)
        clock.now = 105
        self.assertEqual(cache.get("a"), 1)
        clock.now = 120
        self.assertEqual(cache.get("a", "gone"), "gone")

    def test_default_ttl_applies(self):
        clock = FakeClock(0)
        cache = LRUCache(default_ttl=5, clock=clock)
        cache.set("a", 1)
        clock.now = 9
        self.assertIsNone(cache.get("a"))

    def test_contains_present_key(self):
        cache = LRUCache()
        cache.set("a", 1)
        self.assertIn("a", cache)


class StatsTest(unittest.TestCase):
    def test_counts_hits_and_misses(self):
        cache = LRUCache()
        cache.set("a", 1)
        cache.get("a")
        cache.get("b")
        self.assertEqual((cache.stats.hits, cache.stats.misses), (1, 1))

    def test_counts_evictions(self):
        cache = LRUCache(max_size=1)
        cache.set("a", 1)
        cache.set("b", 2)
        self.assertEqual(cache.stats.evictions, 1)


if __name__ == "__main__":
    unittest.main()
