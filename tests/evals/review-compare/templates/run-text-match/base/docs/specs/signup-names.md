# Check usernames, display names and tags at sign-up

`Registry.add(username, display_name)` creates an account, and
`Registry.set_tags(username, field)` stores the tags a user typed into one
text box. The text rules live in `names/text.py`.

## Usernames

- A username is 3 to 20 characters: ASCII letters, ASCII digits and `_`,
  starting with a letter. Nothing else is allowed, including a trailing
  newline. A bad username raises `BadUsername`.
- Usernames are unique without regard to case: `Alice` is taken once
  `alice` exists (`Taken`).
- These words are reserved: `admin`, `root`, `support`, `system`, `staff`.
  A username is reserved if it is one of them in any case, also after
  removing any trailing digits and underscores, so `Admin`, `root7` and
  `admin_2` are all reserved (`BadUsername`). `administrator` is not.

## Display names

- `normalize_name(name)` gives the key used to spot duplicate display
  names. Two names are the same person's name when they differ only in
  case, including full Unicode case folding (`Straße` and `STRASSE` match),
  in Unicode composition (an `é` typed as one code point or as `e` plus a
  combining accent match), or in spacing (leading, trailing and repeated
  spaces do not count).
- `add` raises `Taken` when the display name matches an existing one.

## Tags

- `parse_tags(field)` splits the field on commas and returns the cleaned
  tags in their first-seen order, without duplicates. Spaces around each
  tag are ignored, and empty entries (`a,,b`) are skipped. An empty field
  gives no tags.
- A tag that contains a comma is written in double quotes, for example
  `jam, "salt, pepper"`; the quotes are not part of the tag. A quoted tag
  may come anywhere in the field, after a space or not.
- One leading `#` is dropped (`#news` is `news`); any other `#` is not
  allowed, so `##news` is rejected.
- A tag may contain only ASCII letters, ASCII digits, `-`, spaces and
  commas, and is at most 30 characters. Repeated spaces inside a tag become
  one. Tags are stored in lower case.
- A tag that is empty after dropping the `#` (a lone `#`) is rejected.
- Any rejected tag raises `BadTag`, and no tags are stored.
