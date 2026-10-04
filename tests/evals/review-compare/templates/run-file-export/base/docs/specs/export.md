# Export a user's files

`export_files(source_dir, export_dir, names=None, compress=False, level=None)`
copies the files under `source_dir` into `export_dir` and returns the list of
exported file names, sorted.

- `source_dir` is searched including subfolders. Every exported file is
  placed directly in `export_dir` (no subfolders), under its own base name.
- If `source_dir` does not exist, raise `FileNotFoundError`. The export
  folder is created, with any missing parent folders, even when there is
  nothing to export; an empty source folder returns an empty list.
- Hidden files and hidden folders (names starting with a dot) are skipped,
  together with everything inside a hidden folder at any depth.
- Symbolic links are not exported, whether they point to a file or a folder.
- `names` maps a file's path relative to `source_dir` (with `/` between
  parts) to a name the user chose for it in the export. Only the base name
  of a chosen name is used, so `../x.txt`, `sub/x.txt` and `/tmp/x.txt` all
  become `x.txt` inside `export_dir`. Nothing is ever written outside
  `export_dir`.
- Export names are tidied by `export_name(name)`:
  - the prefix `draft-` is removed when the name begins with it; nothing
    else in the name changes;
  - the extension, which is the part from the last dot, is renamed using
    `RENAMES` (`.jpeg` to `.jpg`, `.htm` to `.html`, `.yml` to `.yaml`),
    matched ignoring case. Only the last extension changes, so
    `photo.v2.jpeg` becomes `photo.v2.jpg`.
- With `compress=True`, each exported file is gzipped by running a separate
  local Python process; the original is removed and the listed name ends in
  `.gz`. `level` is the gzip level from 0 to 9 and defaults to 6 when not
  given; level 0 stores the data without compressing it. File names and
  folders may contain spaces.
