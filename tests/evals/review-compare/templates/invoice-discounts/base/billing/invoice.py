"""Invoices for the billing service."""
from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")


def to_cents(amount):
    """Round a Decimal amount to whole cents, halves away from zero."""
    return amount.quantize(CENT, rounding=ROUND_HALF_UP)


@dataclass
class LineItem:
    sku: str
    unit_price: Decimal
    quantity: int = 1

    def total(self):
        return to_cents(self.unit_price * self.quantity)


@dataclass
class Invoice:
    customer: str
    items: list = field(default_factory=list)

    def add(self, sku, unit_price, quantity=1):
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        self.items.append(LineItem(sku, Decimal(str(unit_price)), quantity))

    def subtotal(self):
        return to_cents(sum((item.total() for item in self.items), Decimal("0")))
