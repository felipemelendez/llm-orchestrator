import unittest
from decimal import Decimal

from billing.invoice import Coupon, Invoice, UnknownRegion


class InvoiceTest(unittest.TestCase):
    def test_subtotal_sums_line_items(self):
        invoice = Invoice("acme")
        invoice.add("A-1", "19.99", 2)
        invoice.add("B-2", "5.00")
        self.assertEqual(invoice.subtotal(), Decimal("44.98"))

    def test_rejects_zero_quantity(self):
        with self.assertRaises(ValueError):
            Invoice("acme").add("A-1", "1.00", 0)


class DiscountTest(unittest.TestCase):
    def test_percent_coupon(self):
        invoice = Invoice("acme")
        invoice.add("A-1", "80.00")
        invoice.apply(Coupon.percent("SAVE10", 10))
        self.assertEqual(invoice.discount(), Decimal("8.00"))

    def test_fixed_coupon(self):
        invoice = Invoice("acme")
        invoice.add("A-1", "80.00")
        invoice.apply(Coupon.fixed("FIVE", 5))
        self.assertEqual(invoice.discount(), Decimal("5.00"))


class TaxTest(unittest.TestCase):
    def test_tax_in_texas(self):
        invoice = Invoice("acme", region="TX")
        invoice.add("A-1", "100.00")
        self.assertEqual(invoice.tax(), Decimal("6.25"))
        self.assertEqual(invoice.summary()["total"], "106.25")

    def test_unknown_region(self):
        invoice = Invoice("acme", region="ZZ")
        invoice.add("A-1", "1.00")
        with self.assertRaises(UnknownRegion):
            invoice.tax()


if __name__ == "__main__":
    unittest.main()
