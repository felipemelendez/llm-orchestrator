"""When to remind users about upcoming subscription charges."""
import calendar
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from zoneinfo import ZoneInfo

DEFAULT_DAYS_BEFORE = 3


@dataclass(frozen=True)
class Reminder:
    name: str
    bills_on: date
    at: datetime


def parse_timestamp(text):
    """Read an ISO 8601 timestamp with an offset or Z and return it in UTC."""
    value = datetime.fromisoformat(text)
    if value.tzinfo is None:
        raise ValueError(f"timestamp has no offset: {text!r}")
    return value.astimezone(UTC)


def add_months(day, months):
    """The same day `months` later, or the last day of that month if it is shorter."""
    index = day.month - 1 + months
    year, month = day.year + index // 12, index % 12 + 1
    last = calendar.monthrange(year, month)[1]
    return date(year, month, min(day.day, last))


def nth_billing_date(sub, n):
    """The date of charge number n; charge 0 is on the start date."""
    if sub.period == "yearly":
        return add_months(sub.start, 12 * n)
    return add_months(sub.start, n)


def billing_dates(sub):
    """Every charge date from the start date on, in order."""
    n = 0
    while True:
        yield nth_billing_date(sub, n)
        n += 1


def reminder_at(sub, bills_on):
    """The UTC moment to remind the user about the charge on `bills_on`."""
    days = DEFAULT_DAYS_BEFORE if sub.days_before is None else sub.days_before
    local = datetime.combine(bills_on - timedelta(days=days), sub.remind_time, tzinfo=ZoneInfo(sub.tz))
    return local.astimezone(UTC)


def upcoming(subs, now, days):
    """Reminders from `now` (included) to `days` days later (excluded), soonest first."""
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)
    end = now + timedelta(days=days)
    found = []
    for sub in subs:
        for bills_on in billing_dates(sub):
            at = reminder_at(sub, bills_on)
            if at >= end:
                break
            if at >= now:
                found.append(Reminder(sub.name, bills_on, at))
    return sorted(found, key=lambda r: (r.at, r.name))
