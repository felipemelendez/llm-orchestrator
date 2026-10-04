"""Currencies the ledger knows: their symbol and number of decimal places."""

CURRENCIES = {
    "USD": ("$", 2),
    "EUR": ("€", 2),
    "GBP": ("£", 2),
    "JPY": ("¥", 0),
}


class UnknownCurrency(KeyError):
    """A currency code the ledger does not know."""


def lookup(code):
    """Return (symbol, places) for a currency code such as "usd" or "JPY"."""
    try:
        return CURRENCIES[code.upper()]
    except KeyError:
        raise UnknownCurrency(code) from None
