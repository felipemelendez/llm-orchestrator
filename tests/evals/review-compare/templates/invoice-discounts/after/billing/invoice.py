"""Invoices for the billing service."""
from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_UP

CENT = Decimal("0.01")
ZERO = Decimal("0")

TAX_RATES = {
    "CA": Decimal("0.0725"),
    "NY": Decimal("0.04"),
    "OR": Decimal("0"),
    "TX": Decimal("0.0625"),
}


class UnknownRegion(ValueError):
    """The customer's region has no entry in TAX_RATES."""


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


@dataclass(frozen=True)
class Coupon:
    code: str
    kind: str
    value: Decimal
    min_subtotal: Decimal = ZERO

    @classmethod
    def percent(cls, code, value, min_subtotal="0"):
        value = Decimal(str(value))
        if not ZERO <= value <= 100:
            raise ValueError("percent must be between 0 and 100")
        return cls(code, "percent", value, Decimal(str(min_subtotal)))

    @classmethod
    def fixed(cls, code, value, min_subtotal="0"):
        value = Decimal(str(value))
        if value < 0:
            raise ValueError("a fixed coupon cannot be negative")
        return cls(code, "fixed", value, Decimal(str(min_subtotal)))

    def discount_on(self, subtotal):
        """The amount this coupon takes off `subtotal`, rounded to cents."""
        if subtotal < self.min_subtotal:
            return ZERO
        if self.kind == "percent":
            return to_cents(subtotal * self.value / 100)
        return to_cents(min(self.value, subtotal))


@dataclass
class Invoice:
    customer: str
    region: str = "OR"
    items: list = field(default_factory=list)
    coupon: Coupon = None

    def add(self, sku, unit_price, quantity=1):
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        self.items.append(LineItem(sku, Decimal(str(unit_price)), quantity))

    def apply(self, coupon):
        """Use `coupon` on this invoice, replacing any coupon applied before."""
        self.coupon = coupon

    def subtotal(self):
        return to_cents(sum((item.total() for item in self.items), ZERO))

    def discount(self):
        if self.coupon is None:
            return ZERO
        return self.coupon.discount_on(self.subtotal())

    def tax_rate(self):
        try:
            return TAX_RATES[self.region]
        except KeyError:
            raise UnknownRegion(self.region) from None

    def tax(self):
        return to_cents((self.subtotal() - self.discount()) * self.tax_rate())

    def total(self):
        return self.subtotal() - self.discount() + self.tax()

    def summary(self):
        return {
            "subtotal": f"{self.subtotal():.2f}",
            "discount": f"{self.discount():.2f}",
            "tax": f"{self.tax():.2f}",
            "total": f"{self.total():.2f}",
        }
