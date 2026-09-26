"""A small in-process cache for the catalog service."""
from collections import OrderedDict


class LRUCache:
    def __init__(self, max_size=128):
        if max_size <= 0:
            raise ValueError("max_size must be positive")
        self.max_size = max_size
        self._data = OrderedDict()

    def get(self, key, default=None):
        if key not in self._data:
            return default
        self._data.move_to_end(key)
        return self._data[key]

    def set(self, key, value):
        self._data[key] = value
        self._data.move_to_end(key)
        if len(self._data) > self.max_size:
            self._data.popitem(last=False)

    def __len__(self):
        return len(self._data)
