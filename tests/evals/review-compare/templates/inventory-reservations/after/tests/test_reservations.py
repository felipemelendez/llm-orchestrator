import unittest
from datetime import datetime, timedelta

from inventory.reservations import ReservationBook
from inventory.stock import OutOfStock, Stock


class Clock:
    def __init__(self):
        self.now = datetime(2026, 3, 1, 12, 0)

    def __call__(self):
        return self.now


class ReservationTest(unittest.TestCase):
    def setUp(self):
        self.stock = Stock()
        self.stock.add("A", 5)
        self.stock.add("B", 5)
        self.clock = Clock()
        self.book = ReservationBook(self.stock, self.clock)

    def test_reserve_holds_stock(self):
        reservation = self.book.reserve("o-1", {"A": 2, "B": 1})
        self.assertEqual(reservation.state, "active")
        self.assertEqual(self.stock.available("A"), 3)
        self.assertEqual(self.stock.available("B"), 4)

    def test_cancel_returns_stock(self):
        reservation = self.book.reserve("o-1", {"A": 2})
        self.book.cancel(reservation.id)
        self.assertEqual(self.stock.available("A"), 5)

    def test_ship_takes_stock_off_the_shelf(self):
        reservation = self.book.reserve("o-1", {"A": 2})
        self.book.ship(reservation.id)
        self.assertEqual(self.stock.on_hand("A"), 3)
        self.assertEqual(self.stock.available("A"), 3)

    def test_too_large_order(self):
        with self.assertRaises(OutOfStock):
            self.book.reserve("o-1", {"A": 6})
        self.assertEqual(self.stock.available("A"), 5)

    def test_expired_reservation_returns_stock(self):
        self.book.reserve("o-1", {"A": 2})
        self.clock.now += timedelta(minutes=20)
        self.assertEqual(self.book.expire_due(), 1)
        self.assertEqual(self.stock.available("A"), 5)


if __name__ == "__main__":
    unittest.main()
