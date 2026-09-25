"""Held-out check for inventory-reservations: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from datetime import datetime, timedelta

sys.path.insert(0, ".")
from inventory.reservations import ReservationBook, ReservationError  # noqa: E402
from inventory.stock import OutOfStock, Stock  # noqa: E402


class Clock:
    def __init__(self):
        self.now = datetime(2026, 3, 1, 12, 0)

    def __call__(self):
        return self.now


def setup():
    stock = Stock()
    stock.add("A", 5)
    stock.add("B", 1)
    clock = Clock()
    return stock, clock, ReservationBook(stock, clock)


def expect(error, call):
    try:
        call()
    except error:
        return
    raise AssertionError(f"expected {error.__name__}")


def check():
    stock, clock, book = setup()
    expect(OutOfStock, lambda: book.reserve("o-1", {"A": 2, "B": 2}))
    assert stock.available("A") == 5, "a failed reservation holds nothing"

    stock, clock, book = setup()
    r = book.reserve("o-1", {"A": 1})
    clock.now = r.expires_at
    expect(ReservationError, lambda: book.cancel(r.id))
    assert stock.available("A") == 5, "expired at exactly the expiry time"

    stock, clock, book = setup()
    book.reserve("o-1", {"A": 1})
    clock.now += timedelta(minutes=15)
    assert book.expire_due() == 1, "expire_due at exactly the expiry time"

    stock, clock, book = setup()
    book.reserve("o-1", {"A": 1})
    expect(ReservationError, lambda: book.reserve("o-1", {"A": 1}))

    stock, clock, book = setup()
    r = book.reserve("o-1", {"A": 1})
    clock.now += timedelta(minutes=10)
    assert book.extend(r.id) == datetime(2026, 3, 1, 12, 25), "extend restarts the hold from now"

    stock, clock, book = setup()
    r = book.reserve("o-1", {"A": 2})
    book.ship(r.id)
    expect(ReservationError, lambda: book.cancel(r.id))
    assert stock.on_hand("A") == 3 and stock.available("A") == 3

    stock = Stock()
    stock.add("A", 5)
    stock.hold("A", 3)
    expect(OutOfStock, lambda: stock.hold("A", 3))
    stock.hold("A", 2)
    assert stock.available("A") == 0

    stock = Stock()
    stock.add("A", 5)
    stock.hold("A", 2)
    expect(ValueError, lambda: stock.release("A", 3))
    assert stock.held("A") == 2

    stock, clock, book = setup()
    book.reserve("o-1", {"A": 2})
    clock.now += timedelta(minutes=16)
    assert book.held_for("o-1") == {}, "an expired hold reports nothing"

    stock, clock, book = setup()
    book.reserve("o-1", {"A": 5})
    clock.now += timedelta(minutes=16)
    book.reserve("o-2", {"A": 5})
    assert book.held_for("o-2") == {"A": 5}


if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(f"held-out check failed: {e!r}")
        sys.exit(1)
    print("held-out check passed")
