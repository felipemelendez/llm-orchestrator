"""Held-out check for ttl-cache: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys

sys.path.insert(0, ".")
from cache.lru import LRUCache  # noqa: E402


class Clock:
    def __init__(self, now=0.0):
        self.now = now

    def __call__(self):
        return self.now


def check():
    clock = Clock(100)
    cache = LRUCache(clock=clock)
    cache.set("a", 1, ttl=10)
    clock.now = 110
    assert cache.get("a") is None, "an entry is gone at exactly its expiry time"
    assert cache.stats.expirations == 1, "an expired get counts an expiration"
    assert cache.stats.misses == 1, "an expired get counts a miss"

    cache = LRUCache(max_size=2)
    cache.set("a", 1)
    cache.set("b", 2)
    cache.get("a")
    cache.set("c", 3)
    assert cache.get("a") == 1, "get marks an entry as recently used"
    assert cache.get("b") is None, "the least recently used entry is evicted"

    for bad in (0, -1):
        try:
            LRUCache().set("x", 1, ttl=bad)
        except ValueError:
            pass
        else:
            raise AssertionError("a ttl of zero or less is accepted")
    try:
        LRUCache(default_ttl=0)
    except ValueError:
        pass
    else:
        raise AssertionError("a default_ttl of zero is accepted")

    clock = Clock(0)
    cache = LRUCache(clock=clock)
    cache.set("a", 1, ttl=5)
    cache.set("b", 2, ttl=50)
    cache.set("c", 3)
    clock.now = 10
    assert cache.purge_expired() == 1, "purge_expired returns how many it removed"
    assert len(cache) == 2
    assert cache.stats.expirations == 1

    clock = Clock(0)
    cache = LRUCache(clock=clock)
    cache.set("a", 1, ttl=5)
    clock.now = 6
    assert "a" not in cache, "an expired key is not in the cache"

    cache = LRUCache()
    assert cache.stats.hit_rate() == 0.0
    cache.set("a", 1)
    cache.get("a")
    cache.get("a")
    cache.get("a")
    cache.get("b")
    assert cache.stats.hit_rate() == 0.75, "hit rate is hits over lookups"

    cache = LRUCache()
    cache.set("a", 1)
    assert cache.delete("a") is True
    assert cache.delete("a") is False, "deleting a missing key returns False"

    clock = Clock(100)
    cache = LRUCache(clock=clock)
    cache.set("a", 1, ttl=10)
    clock.now = 105
    assert cache.get("a") == 1, "ttl counts from the time of set"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
