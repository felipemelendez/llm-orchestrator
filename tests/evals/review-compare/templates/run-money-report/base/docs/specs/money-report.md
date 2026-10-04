# Money report

Add `ledger/report.py`, which totals user-entered line items in one currency
and formats a plain-text report. Amounts are exact decimals throughout.

## Parsing

- `parse_amount(text, currency)` returns a `Decimal`. An amount is digits
  with an optional decimal part, such as `12`, `12.5` or `0.125`. It may use
  commas between groups of three digits (`1,234.50`). It may start with a
  minus sign, then the currency's symbol once, then the number (`-$4.20`,
  `$4.20`, `4.20`). Nothing may come before or after these parts, including
  spaces or a line break. Anything else raises `BadAmount`.
- `parse_quantity(value)` accepts an int of 0 or more, or a string made of
  the ASCII digits 0-9 only. Anything else raises `BadAmount`.

## Rounding and formatting

- `to_minor(value, places)` rounds a `Decimal` to `places` decimal places
  and returns it as a whole number of minor units (cents for USD). Halves
  round away from zero: `0.125` gives 13 cents and `-0.125` gives -13.
- `format_money(minor, currency)` writes the sign, then the symbol, then the
  whole part with commas between thousands, then the decimal part padded to
  the currency's places: `$1,234.50`, `-$1.50`, `¥1,200`. Refunds are
  negative amounts and are formatted the same way.

## Report

`build_report(items, currency)` takes a list of dicts with `sku` (a string
of digits), `name`, `price` (a string for `parse_amount`) and an optional
`qty` (for `parse_quantity`). A missing `qty` means 1; a `qty` of 0 is
allowed and makes that line 0.

- One row per item, `<sku> <name>: <line total>`, ordered by sku as a number
  (sku 9 comes before sku 10).
- Each row shows its line total (price times quantity) rounded with
  `to_minor`. The last row is `Total: <amount>`, where the amount is the
  exact sum of the unrounded line totals, rounded once.
- An empty list gives a report with only the total row, such as
  `Total: $0.00`.
- Rows are joined with newlines.
