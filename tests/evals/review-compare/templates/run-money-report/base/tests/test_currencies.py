import unittest

from ledger.currencies import UnknownCurrency, lookup


class LookupTest(unittest.TestCase):
    def test_known_codes(self):
        self.assertEqual(lookup("USD"), ("$", 2))
        self.assertEqual(lookup("jpy"), ("¥", 0))

    def test_unknown_code(self):
        with self.assertRaises(UnknownCurrency):
            lookup("XYZ")


if __name__ == "__main__":
    unittest.main()
