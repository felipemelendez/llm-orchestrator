# Stock reservations

- `Stock.hold` sets stock aside for an order. It never holds more than is
  available (on hand minus already held); asking for more raises `OutOfStock`.
  `release` returns held stock and never releases more than is held.
  `ship` removes held stock from the shelf.
- `ReservationBook.reserve(order_id, lines)` holds every line of an order or
  none of them: if any line is short, lines already held are released and
  `OutOfStock` is raised. An order has at most one active reservation.
- A reservation is held for 15 minutes. It is expired from the moment its
  expiry time is reached (at exactly the expiry time, it is expired).
  Expired reservations return their stock, and `reserve` first expires every
  reservation that is due so new orders can use that stock.
- `cancel`, `extend` and `ship` work only on active reservations; otherwise
  they raise `ReservationError`. `extend` restarts the hold from now.
- `held_for(order_id)` reports what is held for the order right now, so an
  expired hold reports nothing.
