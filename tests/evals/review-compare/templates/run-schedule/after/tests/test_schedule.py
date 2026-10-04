import unittest
from datetime import UTC, date, datetime
from itertools import islice

from subs import schedule
from subs.plans import Subscription


class ParseTest(unittest.TestCase):
    def test_utc_suffix(self):
        self.assertEqual(schedule.parse_timestamp("2024-03-01T10:00:00Z"),
                         datetime(2024, 3, 1, 10, 0, tzinfo=UTC))

    def test_offset_required(self):
        with self.assertRaises(ValueError):
            schedule.parse_timestamp("2024-03-01T10:00:00")


class BillingTest(unittest.TestCase):
    def test_add_months(self):
        self.assertEqual(schedule.add_months(date(2024, 1, 15), 2), date(2024, 3, 15))

    def test_monthly_dates(self):
        sub = Subscription("music", date(2024, 1, 15), "monthly", 999)
        self.assertEqual(list(islice(schedule.billing_dates(sub), 3)),
                         [date(2024, 1, 15), date(2024, 2, 15), date(2024, 3, 15)])

    def test_yearly_dates(self):
        sub = Subscription("news", date(2023, 6, 1), "yearly", 12000)
        self.assertEqual(list(islice(schedule.billing_dates(sub), 3)),
                         [date(2023, 6, 1), date(2024, 6, 1), date(2025, 6, 1)])


class ReminderTest(unittest.TestCase):
    def test_default_three_days_before(self):
        sub = Subscription("music", date(2024, 1, 15), "monthly", 999)
        self.assertEqual(schedule.reminder_at(sub, date(2024, 2, 15)),
                         datetime(2024, 2, 12, 9, 0, tzinfo=UTC))

    def test_user_time_zone(self):
        sub = Subscription("gym", date(2024, 1, 20), "monthly", 2500, days_before=2, tz="Europe/Paris")
        self.assertEqual(schedule.reminder_at(sub, date(2024, 6, 20)),
                         datetime(2024, 6, 18, 7, 0, tzinfo=UTC))


class UpcomingTest(unittest.TestCase):
    def test_window_sorted(self):
        subs = [Subscription("news", date(2023, 12, 20), "monthly", 500, days_before=1),
                Subscription("music", date(2024, 1, 15), "monthly", 999)]
        found = schedule.upcoming(subs, datetime(2024, 1, 1, 12, 0, tzinfo=UTC), 40)
        self.assertEqual([(r.name, r.bills_on, r.at) for r in found], [
            ("music", date(2024, 1, 15), datetime(2024, 1, 12, 9, 0, tzinfo=UTC)),
            ("news", date(2024, 1, 20), datetime(2024, 1, 19, 9, 0, tzinfo=UTC)),
        ])

    def test_empty_window(self):
        subs = [Subscription("music", date(2024, 1, 15), "monthly", 999)]
        self.assertEqual(schedule.upcoming(subs, datetime(2024, 1, 13, tzinfo=UTC), 7), [])


if __name__ == "__main__":
    unittest.main()
