"""Held-out check for run-money-report: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from decimal import Decimal

sys.path.insert(0, ".")
from ledger import report  # noqa: E402


def bad(fn, *args):
    try:
        fn(*args)
    except report.BadAmount:
        return True
    except Exception as other:
        raise AssertionError(f"{args!r} raised {type(other).__name__}, not BadAmount")
    return False


def check():
    assert report.parse_amount("-$4.20", "USD") == Decimal("-4.20")
    for text in ("$$5", "5\n", "12abc", " 5", "1,23", ""):
        assert bad(report.parse_amount, text, "USD"), f"amount {text!r} accepted"
    assert report.parse_quantity("0") == 0 and report.parse_quantity(0) == 0
    for value in ("²", "٣", "1_000", " 7", "+3", -1):
        assert bad(report.parse_quantity, value), f"quantity {value!r} accepted"

    assert report.to_minor(Decimal("0.125"), 2) == 13, "halves round up"
    assert report.to_minor(Decimal("2.5"), 0) == 3, "halves round up"
    assert report.to_minor(Decimal("-0.125"), 2) == -13, "negative halves round away from zero"
    assert report.format_money(-150, "USD") == "-$1.50", report.format_money(-150, "USD")
    assert report.format_money(-123456, "EUR") == "-€1,234.56"
    assert report.format_money(-5, "JPY") == "-¥5"

    items = [
        {"sku": "10", "name": "Tape", "price": "$0.005", "qty": 3},
        {"sku": "9", "name": "Clips", "price": "$2.00", "qty": 0},
        {"sku": "100", "name": "Refund", "price": "-$1.50"},
    ]
    got = report.build_report(items, "USD")
    want = "9 Clips: $0.00\n10 Tape: $0.02\n100 Refund: -$1.50\nTotal: -$1.49"
    assert got == want, f"report was {got!r}"
    assert report.build_report([], "USD") == "Total: $0.00"
    assert report.build_report([], "JPY") == "Total: ¥0"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
