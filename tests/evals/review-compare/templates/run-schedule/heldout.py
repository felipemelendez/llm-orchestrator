"""Held-out check for run-schedule: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import os
import sys
import time
from datetime import UTC, date, datetime, timedelta, timezone
from itertools import islice

# A naive `now` must mean UTC whatever the computer's zone is, so run in a zone that is not UTC.
os.environ["TZ"] = "America/New_York"
time.tzset()

sys.path.insert(0, ".")
from subs import schedule  # noqa: E402
from subs.plans import Subscription  # noqa: E402


def first(sub, n):
    return list(islice(schedule.billing_dates(sub), n))


def check():
    parse = schedule.parse_timestamp
    assert parse("2024-03-01T10:00:00Z") == datetime(2024, 3, 1, 10, tzinfo=UTC)
    moment = parse("2024-03-01T12:00:00+02:00")
    assert moment == datetime(2024, 3, 1, 10, tzinfo=UTC) and moment.utcoffset() == timedelta(0), \
        f"an offset is converted to UTC, got {moment!r}"
    assert parse("2024-03-01T12:00:00.250+02:00") == datetime(2024, 3, 1, 10, 0, 0, 250000, tzinfo=UTC), \
        "fractional seconds are allowed"
    try:
        parse("2024-03-01T10:00:00")
    except ValueError:
        pass
    else:
        raise AssertionError("a timestamp without an offset is a ValueError")

    assert schedule.add_months(date(2024, 11, 30), 1) == date(2024, 12, 30)
    assert schedule.add_months(date(2024, 12, 31), 2) == date(2025, 2, 28)

    monthly = Subscription("box", date(2024, 1, 31), "monthly", 100)
    got = first(monthly, 5)
    assert got == [date(2024, 1, 31), date(2024, 2, 29), date(2024, 3, 31), date(2024, 4, 30),
                   date(2024, 5, 31)], f"each charge counts from the start date, got {got}"

    leap = Subscription("club", date(2024, 2, 29), "yearly", 100)
    try:
        got = first(leap, 5)
    except ValueError as e:
        raise AssertionError(f"a yearly plan from 29 February raised {e}")
    assert got == [date(2024, 2, 29), date(2025, 2, 28), date(2026, 2, 28), date(2027, 2, 28),
                   date(2028, 2, 29)], f"29 February plan, got {got}"

    # US clocks go forward on 10 March 2024; the reminder stays at 09:00 New York time.
    ny = Subscription("tv", date(2024, 1, 12), "monthly", 100, tz="America/New_York")
    got = schedule.reminder_at(ny, date(2024, 3, 12))
    assert got == datetime(2024, 3, 9, 14, tzinfo=UTC), f"09:00 EST on 9 March is 14:00 UTC, got {got}"

    same_day = Subscription("cloud", date(2024, 1, 5), "monthly", 100, days_before=0)
    got = schedule.reminder_at(same_day, date(2024, 2, 5))
    assert got == datetime(2024, 2, 5, 9, tzinfo=UTC), f"days_before=0 is the day itself, got {got}"

    daily = [Subscription("a", date(2024, 5, 20), "monthly", 100, days_before=3),   # at 05-17 09:00
             Subscription("b", date(2024, 5, 13), "monthly", 100, days_before=3),   # at 05-10 09:00
             Subscription("c", date(2024, 5, 20), "monthly", 100, days_before=2)]   # at 05-18 09:00
    now = datetime(2024, 5, 10, 9, tzinfo=UTC)
    got = [(r.name, r.at) for r in schedule.upcoming(daily, now, 8)]
    assert got == [("b", datetime(2024, 5, 10, 9, tzinfo=UTC)), ("a", datetime(2024, 5, 17, 9, tzinfo=UTC))], \
        f"window is from now (included) to exactly 8x24h later (excluded), got {got}"
    later = datetime(2024, 5, 10, 15, tzinfo=UTC)
    got = [r.name for r in schedule.upcoming(daily, later, 7)]
    assert got == ["a"], f"a window ending mid-day keeps reminders before that moment, got {got}"

    naive = [r.name for r in schedule.upcoming(daily, datetime(2024, 5, 10, 9), 8)]
    assert naive == ["b", "a"], f"a naive now is UTC, got {naive}"

    tie = [Subscription("zeta", date(2024, 5, 20), "monthly", 100),
           Subscription("alpha", date(2024, 5, 20), "monthly", 100)]
    got = [r.name for r in schedule.upcoming(tie, datetime(2024, 5, 1, tzinfo=timezone.utc), 30)]
    assert got == ["alpha", "zeta"], f"ties ordered by name, got {got}"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
