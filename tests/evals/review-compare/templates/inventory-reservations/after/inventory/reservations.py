"""Reservations: stock held for an order until it ships, is cancelled, or expires."""
import itertools
from dataclasses import dataclass
from datetime import timedelta

from inventory.stock import OutOfStock

HOLD_FOR = timedelta(minutes=15)


class ReservationError(Exception):
    """The reservation does not exist or is no longer active."""


@dataclass
class Reservation:
    id: int
    order_id: str
    lines: dict
    expires_at: object
    state: str = "active"


class ReservationBook:
    def __init__(self, stock, clock, hold_for=HOLD_FOR):
        self._stock = stock
        self._clock = clock
        self._hold_for = hold_for
        self._ids = itertools.count(1)
        self._by_id = {}
        self._by_order = {}

    def reserve(self, order_id, lines):
        """Hold every line of an order, or none of them."""
        previous = self._by_order.get(order_id)
        if previous is not None and self._by_id[previous].state == "active":
            raise ReservationError(f"order {order_id} already has an active reservation")
        if not lines:
            raise ValueError("a reservation needs at least one line")
        self.expire_due()
        taken = []
        try:
            for sku, quantity in lines.items():
                self._stock.hold(sku, quantity)
                taken.append((sku, quantity))
        except OutOfStock:
            for sku, quantity in taken:
                self._stock.release(sku, quantity)
            raise
        reservation = Reservation(next(self._ids), order_id, dict(lines),
                                  self._clock() + self._hold_for)
        self._by_id[reservation.id] = reservation
        self._by_order[order_id] = reservation.id
        return reservation

    def get(self, reservation_id):
        try:
            return self._by_id[reservation_id]
        except KeyError:
            raise ReservationError(f"no reservation {reservation_id}") from None

    def _active(self, reservation_id):
        reservation = self.get(reservation_id)
        if reservation.state == "active" and self._clock() >= reservation.expires_at:
            self._end(reservation, "expired")
        if reservation.state != "active":
            raise ReservationError(f"reservation {reservation_id} is {reservation.state}")
        return reservation

    def _end(self, reservation, state):
        for sku, quantity in reservation.lines.items():
            self._stock.release(sku, quantity)
        reservation.state = state

    def cancel(self, reservation_id):
        self._end(self._active(reservation_id), "cancelled")

    def extend(self, reservation_id):
        """Restart the hold from now; return the new expiry."""
        reservation = self._active(reservation_id)
        reservation.expires_at = self._clock() + self._hold_for
        return reservation.expires_at

    def ship(self, reservation_id):
        reservation = self._active(reservation_id)
        for sku, quantity in reservation.lines.items():
            self._stock.ship(sku, quantity)
        reservation.state = "shipped"

    def expire_due(self):
        """End every active reservation whose hold has run out; return how many ended."""
        now = self._clock()
        due = [r for r in self._by_id.values() if r.state == "active" and now >= r.expires_at]
        for reservation in due:
            self._end(reservation, "expired")
        return len(due)

    def held_for(self, order_id):
        """The lines currently held for `order_id`, or an empty dict."""
        self.expire_due()
        reservation_id = self._by_order.get(order_id)
        if reservation_id is None:
            return {}
        reservation = self._by_id[reservation_id]
        return dict(reservation.lines) if reservation.state == "active" else {}
