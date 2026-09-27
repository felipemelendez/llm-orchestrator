import unittest
from datetime import date

from settlement.calendar import BusinessCalendar, add_days, is_weekend


class CalendarTest(unittest.TestCase):
    def test_weekend(self):
        self.assertTrue(is_weekend(date(2026, 3, 7)))
        self.assertFalse(is_weekend(date(2026, 3, 6)))

    def test_add_days(self):
        self.assertEqual(add_days(date(2026, 3, 6), 3), date(2026, 3, 9))


class BusinessCalendarTest(unittest.TestCase):
    def test_holiday_is_not_a_business_day(self):
        calendar = BusinessCalendar([date(2026, 3, 4)])
        self.assertFalse(calendar.is_business_day(date(2026, 3, 4)))
        self.assertFalse(calendar.is_business_day(date(2026, 3, 7)))
        self.assertTrue(calendar.is_business_day(date(2026, 3, 5)))

    def test_next_business_day_skips_weekend(self):
        calendar = BusinessCalendar()
        self.assertEqual(calendar.next_business_day(date(2026, 3, 7)), date(2026, 3, 9))

    def test_add_business_days_forward(self):
        calendar = BusinessCalendar()
        self.assertEqual(calendar.add_business_days(date(2026, 3, 2), 3), date(2026, 3, 5))

    def test_business_days_between_a_week(self):
        calendar = BusinessCalendar()
        self.assertEqual(calendar.business_days_between(date(2026, 3, 2), date(2026, 3, 7)), 5)


if __name__ == "__main__":
    unittest.main()
