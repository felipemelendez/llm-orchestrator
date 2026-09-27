import unittest
from datetime import date

from schedule.events import Event


class EventTest(unittest.TestCase):
    def test_single_event_in_window(self):
        event = Event("Launch", date(2026, 4, 10))
        self.assertEqual(event.occurrences(date(2026, 4, 1), date(2026, 4, 30)), [date(2026, 4, 10)])
        self.assertEqual(event.occurrences(date(2026, 5, 1), date(2026, 5, 31)), [])


if __name__ == "__main__":
    unittest.main()
