"""Checks for single fields of a customer row."""
import re
from datetime import date

PLANS = ("free", "pro", "team")
MIN_AGE = 13
MAX_AGE = 120
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class FieldError(ValueError):
    """A field value that breaks the import rules."""


def check_email(value):
    email = value.strip().lower()
    if not EMAIL.match(email):
        raise FieldError("not a valid address")
    return email


def check_name(value):
    name = value.strip()
    if not name:
        raise FieldError("is required")
    return name


def check_plan(value):
    plan = value.strip().lower()
    if plan not in PLANS:
        raise FieldError(f"must be one of {', '.join(PLANS)}")
    return plan


def check_age(value):
    if not value.strip():
        return None
    try:
        age = int(value)
    except ValueError:
        raise FieldError("must be a whole number") from None
    if not MIN_AGE <= age <= MAX_AGE:
        raise FieldError(f"must be between {MIN_AGE} and {MAX_AGE}")
    return age


def check_signup_date(value, today):
    if not value.strip():
        return None
    try:
        day = date.fromisoformat(value.strip())
    except ValueError:
        raise FieldError("must be a date like 2026-01-31") from None
    if day > today:
        raise FieldError("is in the future")
    return day
