import unittest

from inventory.stock import OutOfStock, Stock


class StockTest(unittest.TestCase):
    def test_add_and_available(self):
        stock = Stock()
        stock.add("A", 5)
        stock.add("A", 2)
        self.assertEqual(stock.available("A"), 7)

    def test_rejects_zero(self):
        with self.assertRaises(ValueError):
            Stock().add("A", 0)

    def test_hold_reduces_available(self):
        stock = Stock()
        stock.add("A", 5)
        stock.hold("A", 2)
        self.assertEqual(stock.available("A"), 3)
        self.assertEqual(stock.on_hand("A"), 5)

    def test_cannot_hold_more_than_available(self):
        stock = Stock()
        stock.add("A", 5)
        stock.hold("A", 3)
        with self.assertRaises(OutOfStock):
            stock.hold("A", 3)


if __name__ == "__main__":
    unittest.main()
