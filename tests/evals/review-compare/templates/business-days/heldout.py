"""Held-out check for business-days: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from datetime import date

sys.path.insert(0, ".")
from settlement.calendar import BusinessCalendar  # noqa: E402


def check():
    # 2026-07-04 is a Saturday, observed on Friday 2026-07-03.
    calendar = BusinessCalendar([date(2026, 7, 4)])
    assert not calendar.is_business_day(date(2026, 7, 3)), "a Saturday holiday is observed on Friday"
    # 2026-01-04 is a Sunday, observed on Monday 2026-01-05.
    calendar = BusinessCalendar([date(2026, 1, 4)])
    assert not calendar.is_business_day(date(2026, 1, 5)), "a Sunday holiday is observed on Monday"
    calendar = BusinessCalendar([date(2026, 7, 4)], observe_weekend_holidays=False)
    assert calendar.is_business_day(date(2026, 7, 3)), "without observing, Friday stays a business day"

    calendar = BusinessCalendar()
    assert calendar.next_business_day(date(2026, 3, 6)) == date(2026, 3, 9), "strictly after a Friday"
    assert calendar.next_business_day(date(2026, 3, 3)) == date(2026, 3, 4)

    assert calendar.add_business_days(date(2026, 3, 9), -1) == date(2026, 3, 6), "negative count moves back"
    assert calendar.add_business_days(date(2026, 3, 11), -3) == date(2026, 3, 6)
    assert calendar.add_business_days(date(2026, 3, 7), 0) == date(2026, 3, 7), "count 0 returns start"

    calendar = BusinessCalendar([date(2026, 3, 4)])
    assert calendar.add_business_days(date(2026, 3, 2), 3) == date(2026, 3, 6), "holidays are skipped"

    calendar = BusinessCalendar()
    assert calendar.business_days_between(date(2026, 3, 2), date(2026, 3, 9)) == 5, "end is not counted"
    assert calendar.business_days_between(date(2026, 3, 2), date(2026, 3, 3)) == 1, "start is counted"
    assert calendar.business_days_between(date(2026, 3, 9), date(2026, 3, 2)) == -5, "reversed range is negative"
    assert calendar.business_days_between(date(2026, 3, 2), date(2026, 3, 2)) == 0


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
