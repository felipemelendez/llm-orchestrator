import unittest
from datetime import date

from subs.plans import Subscription, monthly_cost_cents


class PlansTest(unittest.TestCase):
    def test_monthly_cost(self):
        sub = Subscription("music", date(2024, 1, 15), "monthly", 999)
        self.assertEqual(monthly_cost_cents(sub), 999)

    def test_yearly_cost_per_month(self):
        sub = Subscription("news", date(2024, 1, 15), "yearly", 12000)
        self.assertEqual(monthly_cost_cents(sub), 1000)

    def test_unknown_period(self):
        with self.assertRaises(ValueError):
            Subscription("gym", date(2024, 1, 15), "weekly", 500)


if __name__ == "__main__":
    unittest.main()
