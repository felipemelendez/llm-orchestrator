# Paginate the items endpoint

- `list_page(items, status=None, limit=None, cursor=None)` returns one page of
  the items `list_items` would return: a dict with `items`, `next_cursor` and
  `total`.
- `limit` defaults to 20. A limit above 100 is lowered to 100. A limit below 1
  is an error (`ValueError`).
- `cursor` is opaque to clients. `None` means the first page. The
  `next_cursor` of one page, passed back, gives the next page, with no item
  skipped or repeated.
- `next_cursor` is `None` on the last page, including when the last page is
  exactly full.
- A cursor that cannot be decoded, or that points before the first item, is an
  error (`InvalidCursor`). It never silently restarts from the first page.
- `total` is the number of items that match the status filter, across all
  pages.
