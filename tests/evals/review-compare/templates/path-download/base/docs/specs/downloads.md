# Let users download their uploads

`download(storage, user_id, name)` returns a dict with `body`, `content_type`
and `disposition` for one file in the user's folder `<storage>/<user_id>`.

- `user_id` must be letters and digits only; anything else is `Forbidden`.
- `name` may name a file in a subfolder. After resolving `..` and symbolic
  links, the file must be inside the user's own folder; otherwise the
  request is `Forbidden`. A folder named like the user plus a suffix (`bob2`
  for `bob`) is not inside `bob`. An empty name, the folder itself, or a name
  containing a NUL byte is `Forbidden`.
- A name that is not an existing regular file (including a subfolder) is
  `NotFound`.
- A file larger than `MAX_BYTES` is `TooLarge`; a file of exactly
  `MAX_BYTES` is served whole.
- `content_type` comes from the file extension, compared case-insensitively:
  `.txt` and `.csv` as UTF-8 text, `.pdf`, `.png`, `.jpg`/`.jpeg`. Anything
  else, including `.html` and `.svg`, is `application/octet-stream`.
- `disposition` is `inline` for text and images and `attachment` for
  everything else, with `filename="<base name>"`; double quotes are removed
  from the name.
