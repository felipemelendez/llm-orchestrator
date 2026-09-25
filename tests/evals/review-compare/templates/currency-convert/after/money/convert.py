"""Convert and format money in several currencies."""
from decimal import Decimal, ROUND_HALF_UP

MINOR_UNITS = {"USD": 2, "EUR": 2, "GBP": 2, "JPY": 0, "KWD": 3}
SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"}


class UnknownCurrency(ValueError):
    """The currency code is not in MINOR_UNITS."""


class MissingRate(LookupError):
    """The rate table has no rate for a currency."""


def minor_units(currency):
    try:
        return MINOR_UNITS[currency]
    except KeyError:
        raise UnknownCurrency(currency) from None


def round_amount(amount, currency):
    """Round to the currency's minor unit, halves away from zero."""
    return amount.quantize(Decimal(1).scaleb(-minor_units(currency)), rounding=ROUND_HALF_UP)


class RateTable:
    """Exchange rates, each given as units of the currency per one unit of `base`."""

    def __init__(self, base="USD"):
        minor_units(base)
        self.base = base
        self._rates = {base: Decimal(1)}

    def set(self, currency, rate):
        minor_units(currency)
        rate = Decimal(str(rate))
        if rate <= 0:
            raise ValueError("a rate must be positive")
        self._rates[currency] = rate

    def rate(self, source, target):
        try:
            return self._rates[target] / self._rates[source]
        except KeyError as missing:
            raise MissingRate(missing.args[0]) from None

    def convert(self, amount, source, target):
        """Convert `amount` of `source` into `target`, rounding once at the end."""
        amount = Decimal(str(amount))
        if source == target:
            return round_amount(amount, target)
        return round_amount(amount * self.rate(source, target), target)


def to_minor(amount, currency):
    """The amount as a whole number of minor units, such as cents."""
    return int(round_amount(Decimal(str(amount)), currency).scaleb(minor_units(currency)))


def format_amount(amount, currency):
    """Format for display: "$1,234.50", "¥1,235", or "1.500 KWD" when there is no symbol."""
    amount = round_amount(Decimal(str(amount)), currency)
    sign = "-" if amount < 0 else ""
    digits = f"{abs(amount):,.{minor_units(currency)}f}"
    symbol = SYMBOLS.get(currency)
    if symbol is None:
        return f"{sign}{digits} {currency}"
    return f"{sign}{symbol}{digits}"
