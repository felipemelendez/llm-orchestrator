"""A small in-process cache for the catalog service."""
import time
from collections import OrderedDict
from dataclasses import dataclass


@dataclass
class Stats:
    hits: int = 0
    misses: int = 0
    evictions: int = 0
    expirations: int = 0

    def hit_rate(self):
        total = self.hits + self.misses
        if total == 0:
            return 0.0
        return self.hits / total


class LRUCache:
    def __init__(self, max_size=128, default_ttl=None, clock=time.monotonic):
        if max_size <= 0:
            raise ValueError("max_size must be positive")
        if default_ttl is not None and default_ttl <= 0:
            raise ValueError("default_ttl must be positive")
        self.max_size = max_size
        self.default_ttl = default_ttl
        self._clock = clock
        self._data = OrderedDict()
        self.stats = Stats()

    def _expired(self, expires_at, now):
        return expires_at is not None and now >= expires_at

    def get(self, key, default=None):
        entry = self._data.get(key)
        if entry is None:
            self.stats.misses += 1
            return default
        value, expires_at = entry
        if self._expired(expires_at, self._clock()):
            del self._data[key]
            self.stats.expirations += 1
            self.stats.misses += 1
            return default
        self._data.move_to_end(key)
        self.stats.hits += 1
        return value

    def set(self, key, value, ttl=None):
        if ttl is None:
            ttl = self.default_ttl
        elif ttl <= 0:
            raise ValueError("ttl must be positive")
        expires_at = None if ttl is None else self._clock() + ttl
        self._data[key] = (value, expires_at)
        self._data.move_to_end(key)
        while len(self._data) > self.max_size:
            self._data.popitem(last=False)
            self.stats.evictions += 1

    def delete(self, key):
        return self._data.pop(key, None) is not None

    def purge_expired(self):
        now = self._clock()
        expired = [k for k, (_, expires_at) in self._data.items() if self._expired(expires_at, now)]
        for key in expired:
            del self._data[key]
        self.stats.expirations += len(expired)
        return len(expired)

    def __contains__(self, key):
        entry = self._data.get(key)
        return entry is not None and not self._expired(entry[1], self._clock())

    def __len__(self):
        return len(self._data)
