"""Stock levels per SKU, with quantities held for open orders."""


class OutOfStock(Exception):
    """There is not enough available stock for the request."""


class Stock:
    def __init__(self):
        self._on_hand = {}
        self._held = {}

    def add(self, sku, quantity):
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        self._on_hand[sku] = self._on_hand.get(sku, 0) + quantity

    def on_hand(self, sku):
        return self._on_hand.get(sku, 0)

    def held(self, sku):
        return self._held.get(sku, 0)

    def available(self, sku):
        return self.on_hand(sku) - self.held(sku)

    def hold(self, sku, quantity):
        """Set `quantity` of `sku` aside so no other order can take it."""
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        if quantity > self.available(sku):
            raise OutOfStock(sku)
        self._held[sku] = self.held(sku) + quantity

    def release(self, sku, quantity):
        """Return held stock to the available pool."""
        if quantity > self.held(sku):
            raise ValueError("cannot release more than is held")
        self._held[sku] = self.held(sku) - quantity

    def ship(self, sku, quantity):
        """Remove held stock from the shelf."""
        self.release(sku, quantity)
        self._on_hand[sku] = self.on_hand(sku) - quantity
