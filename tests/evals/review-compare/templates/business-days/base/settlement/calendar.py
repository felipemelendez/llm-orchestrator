"""Calendar helpers for settlement dates."""
from datetime import timedelta

SATURDAY, SUNDAY = 5, 6


def is_weekend(day):
    return day.weekday() >= SATURDAY


def add_days(day, count):
    return day + timedelta(days=count)
