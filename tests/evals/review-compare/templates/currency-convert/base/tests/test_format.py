import unittest

from money.format import format_usd


class FormatTest(unittest.TestCase):
    def test_format_usd(self):
        self.assertEqual(format_usd(123450), "$1,234.50")
        self.assertEqual(format_usd(-5), "-$0.05")


if __name__ == "__main__":
    unittest.main()
