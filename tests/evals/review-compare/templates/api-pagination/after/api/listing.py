"""Listing helpers for the items endpoint."""
import base64
import json

DEFAULT_LIMIT = 20
MAX_LIMIT = 100


class InvalidCursor(ValueError):
    """The cursor could not be decoded."""


def list_items(items, status=None):
    """Items with the given status (all when None), ordered by id."""
    chosen = [item for item in items if status is None or item["status"] == status]
    return sorted(chosen, key=lambda item: item["id"])


def encode_cursor(offset):
    raw = json.dumps({"offset": offset}).encode()
    return base64.urlsafe_b64encode(raw).decode()


def decode_cursor(cursor):
    if cursor is None:
        return 0
    try:
        data = json.loads(base64.urlsafe_b64decode(cursor.encode()))
        offset = int(data["offset"])
    except (ValueError, KeyError, TypeError):
        raise InvalidCursor(cursor) from None
    if offset < 0:
        raise InvalidCursor(cursor)
    return offset


def clamp_limit(limit):
    if limit is None:
        return DEFAULT_LIMIT
    if limit < 1:
        raise ValueError("limit must be at least 1")
    return min(limit, MAX_LIMIT)


def paginate(items, limit=None, cursor=None):
    limit = clamp_limit(limit)
    offset = decode_cursor(cursor)
    page = items[offset:offset + limit]
    end = offset + len(page)
    next_cursor = encode_cursor(end) if end < len(items) else None
    return {"items": page, "next_cursor": next_cursor, "total": len(items)}


def list_page(items, status=None, limit=None, cursor=None):
    return paginate(list_items(items, status), limit, cursor)
