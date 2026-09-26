"""Held-out check for api-pagination: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys

sys.path.insert(0, ".")
from api.listing import InvalidCursor, encode_cursor, list_page  # noqa: E402


def items(n, status="open"):
    return [{"id": i, "status": status} for i in range(n, 0, -1)]


def ids(page):
    return [item["id"] for item in page["items"]]


def walk(data, **kwargs):
    seen, cursor, pages = [], None, 0
    while True:
        page = list_page(data, cursor=cursor, **kwargs)
        seen += ids(page)
        pages += 1
        cursor = page["next_cursor"]
        if cursor is None or pages > 50:
            return seen, pages


def check():
    data = items(45)
    assert len(list_page(data)["items"]) == 20, "default limit is 20"
    assert len(list_page(items(150), limit=500)["items"]) == 100, "limit capped at 100"
    for bad in (0, -3):
        try:
            list_page(data, limit=bad)
        except ValueError:
            pass
        else:
            raise AssertionError("limit below 1 accepted")

    seen, pages = walk(data, limit=10)
    assert seen == list(range(1, 46)), "cursor walk skips or repeats items"
    assert pages == 5, "wrong number of pages"
    seen, pages = walk(items(30), limit=10)
    assert pages == 3, "a full last page still has a next cursor"

    page = list_page(items(5), limit=10)
    assert page["next_cursor"] is None, "single page has a next cursor"

    for bad in ("not-a-cursor", encode_cursor(-5), "e30="):
        try:
            list_page(data, cursor=bad)
        except InvalidCursor:
            pass
        else:
            raise AssertionError(f"cursor {bad!r} accepted")

    mixed = items(6) + [{"id": 100 + i, "status": "closed"} for i in range(4)]
    page = list_page(mixed, status="closed", limit=2)
    assert ids(page) == [100, 101], "status filter ignored"
    assert page["total"] == 4, "total counts every matching item"
    page = list_page(mixed, limit=3, cursor=list_page(mixed, limit=3)["next_cursor"])
    assert page["total"] == 10, "total on a later page"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
