"""Recurrence rules: the dates a repeating event falls on."""
import calendar
from dataclasses import dataclass
from datetime import date, timedelta

FREQUENCIES = ("daily", "weekly", "monthly")
UNITS = {"daily": "day", "weekly": "week", "monthly": "month"}
WEEKDAY_NAMES = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


class RuleError(ValueError):
    """The rule cannot be expanded as given."""


def add_months(day, months):
    """The same day of the month `months` later, or None when that month is too short."""
    index = day.month - 1 + months
    year, month = day.year + index // 12, index % 12 + 1
    if day.day > calendar.monthrange(year, month)[1]:
        return None
    return date(year, month, day.day)


@dataclass(frozen=True)
class Rule:
    frequency: str
    interval: int = 1
    weekdays: tuple = ()
    until: date = None
    count: int = None
    skip: frozenset = frozenset()

    def __post_init__(self):
        if self.frequency not in FREQUENCIES:
            raise RuleError(f"frequency must be one of {', '.join(FREQUENCIES)}")
        if self.interval < 1:
            raise RuleError("interval must be at least 1")
        if self.count is not None and self.count < 1:
            raise RuleError("count must be at least 1")
        if self.until is not None and self.count is not None:
            raise RuleError("give until or count, not both")
        if self.weekdays and self.frequency != "weekly":
            raise RuleError("weekdays apply only to weekly rules")
        if any(not 0 <= weekday <= 6 for weekday in self.weekdays):
            raise RuleError("weekdays run from 0 (Monday) to 6 (Sunday)")


def _candidates(rule, start):
    """Every date the rule could produce from `start`, in order, without end."""
    if rule.frequency == "daily":
        step = 0
        while True:
            yield start + timedelta(days=step)
            step += rule.interval
    elif rule.frequency == "weekly":
        weekdays = sorted(rule.weekdays) or [start.weekday()]
        week_start = start - timedelta(days=start.weekday())
        while True:
            for weekday in weekdays:
                day = week_start + timedelta(days=weekday)
                if day >= start:
                    yield day
            week_start += timedelta(weeks=rule.interval)
    else:
        months = 0
        while True:
            day = add_months(start, months)
            if day is not None:
                yield day
            months += rule.interval


def describe(rule):
    """A short description of the rule, such as "every 2 weeks on Mon, Wed, 5 times"."""
    unit = UNITS[rule.frequency]
    text = f"every {unit}" if rule.interval == 1 else f"every {rule.interval} {unit}s"
    if rule.weekdays:
        text += " on " + ", ".join(WEEKDAY_NAMES[weekday] for weekday in sorted(rule.weekdays))
    if rule.count is not None:
        text += f", {rule.count} time" + ("" if rule.count == 1 else "s")
    elif rule.until is not None:
        text += f", until {rule.until.isoformat()}"
    return text


def expand(rule, start, window_end):
    """The dates from `start` to `window_end`, both included, that the rule produces.

    `count` counts every occurrence the rule produces, skipped dates included,
    so skipping a date never moves the later ones.
    """
    out = []
    produced = 0
    for day in _candidates(rule, start):
        if day > window_end:
            break
        if rule.until is not None and day > rule.until:
            break
        if rule.count is not None and produced >= rule.count:
            break
        produced += 1
        if day not in rule.skip:
            out.append(day)
    return out
