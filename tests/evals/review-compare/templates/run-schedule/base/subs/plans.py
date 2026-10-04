"""Subscriptions a user pays for."""
from dataclasses import dataclass
from datetime import date

PERIODS = ("monthly", "yearly")


@dataclass(frozen=True)
class Subscription:
    name: str
    start: date
    period: str
    price_cents: int

    def __post_init__(self):
        if self.period not in PERIODS:
            raise ValueError(f"unknown period {self.period!r}")
        if self.price_cents < 0:
            raise ValueError("price cannot be negative")


def monthly_cost_cents(sub):
    """What the subscription costs per month, rounded down to a cent."""
    if sub.period == "monthly":
        return sub.price_cents
    return sub.price_cents // 12
