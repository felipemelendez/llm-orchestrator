"""Listing helpers for the items endpoint."""


def list_items(items, status=None):
    """Items with the given status (all when None), ordered by id."""
    chosen = [item for item in items if status is None or item["status"] == status]
    return sorted(chosen, key=lambda item: item["id"])
