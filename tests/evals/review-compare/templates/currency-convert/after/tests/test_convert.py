import unittest
from decimal import Decimal

from money.convert import RateTable, UnknownCurrency, format_amount, to_minor


class ConvertTest(unittest.TestCase):
    def test_format_with_symbol(self):
        self.assertEqual(format_amount("1234.5", "USD"), "$1,234.50")

    def test_format_without_symbol(self):
        self.assertEqual(format_amount("1.5", "KWD"), "1.500 KWD")

    def test_unknown_currency(self):
        with self.assertRaises(UnknownCurrency):
            format_amount("1", "XXX")

    def test_same_currency_rounds(self):
        table = RateTable()
        self.assertEqual(table.convert("10.006", "USD", "USD"), Decimal("10.01"))

    def test_to_minor(self):
        self.assertEqual(to_minor("12.34", "USD"), 1234)
        self.assertEqual(to_minor("1.5", "KWD"), 1500)


if __name__ == "__main__":
    unittest.main()
