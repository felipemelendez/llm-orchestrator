"""Held-out check for invoice-discounts: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from decimal import Decimal

sys.path.insert(0, ".")
from billing.invoice import Coupon, Invoice, UnknownRegion  # noqa: E402


def invoice(region="OR", *prices):
    inv = Invoice("acme", region=region)
    for price in prices:
        inv.add("X", price)
    return inv


def check():
    inv = invoice("OR", "30.00")
    inv.apply(Coupon.fixed("BIG", 50))
    assert inv.discount() == Decimal("30.00"), "fixed coupon larger than the subtotal"
    assert inv.total() == Decimal("0.00"), "total below zero"

    inv = invoice("OR", "50.00")
    inv.apply(Coupon.percent("MIN", 10, min_subtotal="50.00"))
    assert inv.discount() == Decimal("5.00"), "coupon at exactly the minimum"
    inv = invoice("OR", "49.99")
    inv.apply(Coupon.percent("MIN", 10, min_subtotal="50.00"))
    assert inv.discount() == Decimal("0"), "coupon below the minimum"

    inv = invoice("CA", "100.00")
    inv.apply(Coupon.fixed("TEN", 10))
    assert inv.tax() == Decimal("6.53"), "tax on the discounted subtotal, rounded half up"
    assert inv.total() == Decimal("96.53"), "total = discounted subtotal + tax"

    inv = invoice("NY", "10.00")
    inv.apply(Coupon.percent("A", 10))
    inv.apply(Coupon.fixed("B", 2))
    assert inv.discount() == Decimal("2.00"), "a second coupon replaces the first"

    for bad in ("-1", "101"):
        try:
            Coupon.percent("BAD", bad)
        except ValueError:
            pass
        else:
            raise AssertionError("percent outside 0..100 accepted")
    assert Coupon.percent("ALL", 100).discount_on(Decimal("12.00")) == Decimal("12.00")

    try:
        invoice("ZZ", "1.00").total()
    except UnknownRegion:
        pass
    else:
        raise AssertionError("unknown region taxed")

    inv = invoice("OR", "12.5")
    inv.apply(Coupon.percent("Q", 12.5))
    assert inv.discount() == Decimal("1.56"), "percent discount rounded half up"
    assert inv.summary() == {"subtotal": "12.50", "discount": "1.56", "tax": "0.00", "total": "10.94"}

    inv = invoice("OR", "0.25")
    inv.apply(Coupon.percent("H", 10))
    assert inv.discount() == Decimal("0.03"), "a half cent rounds away from zero"

    assert invoice("CA", "10.00").summary()["tax"] == "0.73", "summary reports the tax amount"

    inv = invoice("TX", "0.10", "0.10", "0.10")
    assert inv.tax() == Decimal("0.02"), "tax rounded once on the whole subtotal"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
