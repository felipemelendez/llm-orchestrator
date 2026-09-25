import unittest
from datetime import date

from settlement.calendar import add_days, is_weekend


class CalendarTest(unittest.TestCase):
    def test_weekend(self):
        self.assertTrue(is_weekend(date(2026, 3, 7)))
        self.assertFalse(is_weekend(date(2026, 3, 6)))

    def test_add_days(self):
        self.assertEqual(add_days(date(2026, 3, 6), 3), date(2026, 3, 9))


if __name__ == "__main__":
    unittest.main()
