# Import customers from CSV

`import_customers(text, today, max_errors=None)` reads CSV text and returns an
`ImportResult` with the accepted `rows` and the `errors`.

Header
- The first row is the header. Column names are matched case-insensitively
  and ignoring surrounding spaces. `email`, `name` and `plan` are required;
  `age` and `signup_date` are optional. A missing required column raises
  `HeaderError` naming every missing column.

Rows
- Rows are numbered by their position in the file, the header being line 1,
  so the first data row is line 2. Rows whose cells are all empty or spaces
  are skipped without an error, but still count for numbering.
- `email`: one address, `local@domain.tld`, no spaces; stored lowercased.
  Two rows with the same email, compared case-insensitively, are a
  "duplicate email" error on the later row.
- `name`: required, stored without surrounding spaces.
- `plan`: `free`, `pro` or `team`, in any case; stored lowercased.
- `age`: optional; a whole number from 13 to 120 inclusive. Any other value
  is an error, never silently dropped.
- `signup_date`: optional; an ISO date (`2026-01-31`) that is not after
  `today`. Today itself is allowed.
- A row with any error is rejected as a whole; each broken field is its own
  `RowError(line, field, message)`.

Result
- `rejected` is the number of rejected rows (not errors).
- With `max_errors`, the import stops once that many rows have been
  rejected, and `truncated` is true.
- `format_report(result)` lists one `line N: field: message` line per error,
  then `A imported, R rejected`, adding ` (stopped early: too many errors)`
  when truncated.
