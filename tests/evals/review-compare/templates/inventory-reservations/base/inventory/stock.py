"""Stock levels per SKU."""


class Stock:
    def __init__(self):
        self._on_hand = {}

    def add(self, sku, quantity):
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        self._on_hand[sku] = self._on_hand.get(sku, 0) + quantity

    def on_hand(self, sku):
        return self._on_hand.get(sku, 0)

    def available(self, sku):
        return self.on_hand(sku)
