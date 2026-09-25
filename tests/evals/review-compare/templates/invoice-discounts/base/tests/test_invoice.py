import unittest
from decimal import Decimal

from billing.invoice import Invoice


class InvoiceTest(unittest.TestCase):
    def test_subtotal_sums_line_items(self):
        invoice = Invoice("acme")
        invoice.add("A-1", "19.99", 2)
        invoice.add("B-2", "5.00")
        self.assertEqual(invoice.subtotal(), Decimal("44.98"))

    def test_rejects_zero_quantity(self):
        with self.assertRaises(ValueError):
            Invoice("acme").add("A-1", "1.00", 0)


if __name__ == "__main__":
    unittest.main()
