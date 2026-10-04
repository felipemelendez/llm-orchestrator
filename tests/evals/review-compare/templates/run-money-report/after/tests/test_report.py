import unittest
from decimal import Decimal

from ledger.report import (BadAmount, build_report, format_money, parse_amount,
                           parse_quantity, to_minor)


class ParseTest(unittest.TestCase):
    def test_amounts(self):
        self.assertEqual(parse_amount("$1,234.50", "USD"), Decimal("1234.50"))
        self.assertEqual(parse_amount("12", "USD"), Decimal("12"))
        self.assertEqual(parse_amount("€3.10", "EUR"), Decimal("3.10"))

    def test_bad_amount(self):
        with self.assertRaises(BadAmount):
            parse_amount("abc", "USD")

    def test_quantities(self):
        self.assertEqual(parse_quantity("3"), 3)
        self.assertEqual(parse_quantity(2), 2)
        with self.assertRaises(BadAmount):
            parse_quantity("x")


class FormatTest(unittest.TestCase):
    def test_to_minor(self):
        self.assertEqual(to_minor(Decimal("2.346"), 2), 235)
        self.assertEqual(to_minor(Decimal("1200"), 0), 1200)

    def test_format(self):
        self.assertEqual(format_money(123450, "USD"), "$1,234.50")
        self.assertEqual(format_money(1200, "JPY"), "¥1,200")
        self.assertEqual(format_money(5, "GBP"), "£0.05")


class ReportTest(unittest.TestCase):
    def test_report(self):
        items = [
            {"sku": "3", "name": "Ink", "price": "$4.00"},
            {"sku": "1", "name": "Pens", "price": "$1.25", "qty": 2},
            {"sku": "2", "name": "Paper", "price": "$7.10", "qty": "3"},
        ]
        self.assertEqual(build_report(items, "USD"),
                         "1 Pens: $2.50\n2 Paper: $21.30\n3 Ink: $4.00\nTotal: $27.80")


if __name__ == "__main__":
    unittest.main()
