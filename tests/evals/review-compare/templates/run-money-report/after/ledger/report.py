"""Total user-entered line items in one currency and format a report."""
import re
from decimal import ROUND_HALF_UP, Decimal

from ledger.currencies import lookup


class BadAmount(ValueError):
    """An amount or quantity that is not a valid number."""


AMOUNT_RE = re.compile(r"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?")


def parse_amount(text, currency):
    """Parse "-$1,234.50" style input into a Decimal."""
    symbol, _ = lookup(currency)
    negative = text.startswith("-")
    if negative:
        text = text[1:]
    text = text.removeprefix(symbol)
    if not AMOUNT_RE.fullmatch(text):
        raise BadAmount(text)
    value = Decimal(text.replace(",", ""))
    return -value if negative else value


def parse_quantity(value):
    """Parse a quantity given as an int or a string of digits."""
    if isinstance(value, int):
        if value < 0:
            raise BadAmount(value)
        return value
    text = str(value)
    if not (text.isascii() and text.isdigit()):
        raise BadAmount(text)
    return int(text)


def to_minor(value, places):
    """Round to `places` decimals, halves away from zero, as whole minor units."""
    rounded = value.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
    return int(rounded.scaleb(places))


def format_money(minor, currency):
    """Format minor units as "-$1,234.50"."""
    symbol, places = lookup(currency)
    sign = "-" if minor < 0 else ""
    whole, frac = divmod(abs(minor), 10**places)
    text = f"{whole:,}"
    if places:
        text += f".{frac:0{places}d}"
    return f"{sign}{symbol}{text}"


def line_total(item, currency):
    """Price times quantity for one item, unrounded."""
    qty = parse_quantity(item.get("qty", 1))
    return parse_amount(item["price"], currency) * qty


def build_report(items, currency):
    """One row per item ordered by sku, then the total row."""
    _, places = lookup(currency)
    ordered = sorted(items, key=lambda item: int(item["sku"]))
    totals = [line_total(item, currency) for item in ordered]
    rows = [
        f"{item['sku']} {item['name']}: {format_money(to_minor(amount, places), currency)}"
        for item, amount in zip(ordered, totals)
    ]
    grand = sum(totals, Decimal(0))
    rows.append(f"Total: {format_money(to_minor(grand, places), currency)}")
    return "\n".join(rows)
