# Expiry and statistics for the LRU cache

- `LRUCache(max_size, default_ttl=None, clock=time.monotonic)`. `clock` returns
  seconds; tests pass a fake clock.
- `set(key, value, ttl=None)` stores the value. With no `ttl`, the entry uses
  `default_ttl`; with neither, it never expires. A `ttl` or `default_ttl` of
  zero or less is a `ValueError`.
- An entry set at time `t` with ttl `n` expires at `t + n`: at that moment and
  after, it is gone.
- `get(key, default=None)` returns the value and marks the entry as most
  recently used. A missing or expired entry returns `default`, counts as a
  miss, and an expired entry is removed and counted as an expiration.
- When the cache holds more than `max_size` entries, the least recently used
  entries are evicted, each counted as an eviction.
- `delete(key)` removes the entry and returns whether it was there.
- `purge_expired()` removes every expired entry and returns how many it
  removed; each counts as an expiration.
- `key in cache` is true only for a present entry that has not expired.
- `stats` has `hits`, `misses`, `evictions` and `expirations`, and
  `stats.hit_rate()` is hits divided by hits plus misses, or 0.0 before any
  lookup.
