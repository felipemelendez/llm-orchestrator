"""Calendar helpers for settlement dates."""
from datetime import timedelta

SATURDAY, SUNDAY = 5, 6
ONE_DAY = timedelta(days=1)


def is_weekend(day):
    return day.weekday() >= SATURDAY


def add_days(day, count):
    return day + timedelta(days=count)


def observed(holiday):
    """The weekday a holiday is observed on: Saturday moves to Friday, Sunday to Monday."""
    if holiday.weekday() == SATURDAY:
        return holiday - ONE_DAY
    if holiday.weekday() == SUNDAY:
        return holiday + ONE_DAY
    return holiday


class BusinessCalendar:
    def __init__(self, holidays=(), observe_weekend_holidays=True):
        if observe_weekend_holidays:
            self.holidays = frozenset(observed(h) for h in holidays)
        else:
            self.holidays = frozenset(holidays)

    def is_business_day(self, day):
        return not is_weekend(day) and day not in self.holidays

    def next_business_day(self, day):
        """The first business day strictly after `day`."""
        day += ONE_DAY
        while not self.is_business_day(day):
            day += ONE_DAY
        return day

    def add_business_days(self, start, count):
        """Move `count` business days from `start`; a negative count moves back."""
        step = ONE_DAY if count >= 0 else -ONE_DAY
        day, remaining = start, abs(count)
        while remaining > 0:
            day += step
            if self.is_business_day(day):
                remaining -= 1
        return day

    def business_days_between(self, start, end):
        """Business days in [start, end); negative when end is before start."""
        if end < start:
            return -self.business_days_between(end, start)
        count = 0
        day = start
        while day < end:
            if self.is_business_day(day):
                count += 1
            day += ONE_DAY
        return count
