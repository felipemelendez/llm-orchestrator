"""Held-out check for currency-convert: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from decimal import Decimal

sys.path.insert(0, ".")
from money.convert import (MissingRate, RateTable, UnknownCurrency,  # noqa: E402
                           format_amount, to_minor)


def expect(error, call):
    try:
        call()
    except error:
        return
    raise AssertionError(f"expected {error.__name__}")


def check():
    table = RateTable()
    table.set("EUR", "0.9")
    table.set("JPY", "150")
    assert table.convert("10", "USD", "EUR") == Decimal("9.00"), "USD to EUR"
    assert table.convert("9", "EUR", "USD") == Decimal("10.00"), "EUR to USD"
    assert table.convert("1", "EUR", "JPY") == Decimal("167"), "cross rate"
    assert format_amount("1234.4", "JPY") == "¥1,234", "JPY has no decimals"
    assert table.convert("10.005", "USD", "EUR") == Decimal("9.00"), "round once, at the end"
    assert format_amount("-5", "EUR") == "-€5.00", "negative amounts"
    expect(ValueError, lambda: table.set("GBP", "0"))
    expect(UnknownCurrency, lambda: table.set("XXX", "1"))
    expect(MissingRate, lambda: table.convert("1", "USD", "GBP"))
    assert to_minor("0.29", "USD") == 29, "no float rounding"
    assert to_minor("1.2345", "KWD") == 1235
    assert format_amount("0.125", "USD") == "$0.13", "halves round away from zero"
    assert format_amount("2.5", "KWD") == "2.500 KWD"


if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(f"held-out check failed: {e!r}")
        sys.exit(1)
    print("held-out check passed")
