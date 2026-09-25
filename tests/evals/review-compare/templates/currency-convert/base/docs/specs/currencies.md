# Multi-currency amounts

- Each currency has a number of minor units: USD, EUR and GBP 2, JPY 0,
  KWD 3. An unknown code raises `UnknownCurrency` everywhere, including when a
  rate is set.
- A `RateTable` holds rates as units of the currency per one unit of its
  base currency. Rates must be positive. A missing rate raises `MissingRate`;
  a conversion never guesses a rate.
- `convert(amount, source, target)` multiplies by the exact cross rate
  (target rate / source rate) and rounds once, to the target's minor unit,
  halves away from zero.
- `to_minor` gives the amount as an integer number of minor units, computed
  in Decimal, never through binary floating point.
- `format_amount` rounds the same way and shows the currency's decimals and
  thousands separators: `$1,234.50`, `¥1,235`, `-€5.00`. A currency with no
  symbol shows its code after the number: `1.500 KWD`.
