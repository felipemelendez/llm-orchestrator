import unittest
from datetime import date

from schedule.events import Event
from schedule.recurrence import Rule, describe


class EventTest(unittest.TestCase):
    def test_single_event_in_window(self):
        event = Event("Launch", date(2026, 4, 10))
        self.assertEqual(event.occurrences(date(2026, 4, 1), date(2026, 4, 30)), [date(2026, 4, 10)])
        self.assertEqual(event.occurrences(date(2026, 5, 1), date(2026, 5, 31)), [])

    def test_window_must_be_ordered(self):
        with self.assertRaises(ValueError):
            Event("Launch", date(2026, 4, 10)).occurrences(date(2026, 5, 1), date(2026, 4, 1))

    def test_daily_with_count(self):
        event = Event("Standup", date(2026, 4, 6), Rule("daily", count=3))
        self.assertEqual(event.occurrences(date(2026, 4, 1), date(2026, 4, 30)),
                         [date(2026, 4, 6), date(2026, 4, 7), date(2026, 4, 8)])

    def test_weekly_on_start_weekday(self):
        event = Event("Review", date(2026, 4, 6), Rule("weekly"))
        self.assertEqual(event.occurrences(date(2026, 4, 1), date(2026, 4, 20)),
                         [date(2026, 4, 6), date(2026, 4, 13), date(2026, 4, 20)])

    def test_monthly(self):
        event = Event("Invoices", date(2026, 1, 15), Rule("monthly"))
        self.assertEqual(event.occurrences(date(2026, 1, 1), date(2026, 3, 31)),
                         [date(2026, 1, 15), date(2026, 2, 15), date(2026, 3, 15)])

    def test_skipped_dates(self):
        event = Event("Gym", date(2026, 4, 6), Rule("daily", skip=frozenset({date(2026, 4, 7)})))
        self.assertEqual(event.occurrences(date(2026, 4, 1), date(2026, 4, 8)),
                         [date(2026, 4, 6), date(2026, 4, 8)])

    def test_next_occurrence_is_strictly_after(self):
        event = Event("Review", date(2026, 4, 6), Rule("weekly"))
        self.assertEqual(event.next_occurrence(date(2026, 4, 13)), date(2026, 4, 20))

    def test_describe(self):
        self.assertEqual(describe(Rule("weekly", interval=2, weekdays=(2, 0), count=5)),
                         "every 2 weeks on Mon, Wed, 5 times")
        self.assertEqual(describe(Rule("daily", until=date(2026, 5, 1))), "every day, until 2026-05-01")
        self.assertEqual(describe(Rule("monthly", count=1)), "every month, 1 time")

    def test_bad_frequency(self):
        with self.assertRaises(ValueError):
            Rule("hourly")


if __name__ == "__main__":
    unittest.main()
