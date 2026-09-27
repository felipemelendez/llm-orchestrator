import unittest

from inventory.stock import Stock


class StockTest(unittest.TestCase):
    def test_add_and_available(self):
        stock = Stock()
        stock.add("A", 5)
        stock.add("A", 2)
        self.assertEqual(stock.available("A"), 7)

    def test_rejects_zero(self):
        with self.assertRaises(ValueError):
            Stock().add("A", 0)


if __name__ == "__main__":
    unittest.main()
