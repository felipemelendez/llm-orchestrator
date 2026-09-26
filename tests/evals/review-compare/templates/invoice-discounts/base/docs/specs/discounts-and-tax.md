# Discounts and tax on invoices

- A coupon is either a percentage (`percent`, 0 to 100) or a fixed amount
  (`fixed`, in dollars). An invoice holds at most one coupon; applying a
  second one replaces the first.
- A percentage coupon takes that share off the subtotal. A fixed coupon takes
  its amount off the subtotal, but never more than the subtotal: the
  discounted subtotal is never below zero.
- A coupon may name a minimum subtotal (`min_subtotal`). Below it, the coupon
  gives no discount. At exactly the minimum, it applies.
- Tax is charged on the discounted subtotal at the rate of the customer's
  region, from `TAX_RATES`. A region not in the table is an error
  (`UnknownRegion`), never a zero rate.
- Each amount (discount, tax, total) is rounded to cents once, half away from
  zero, and `total = discounted subtotal + tax`.
- `summary()` returns the subtotal, discount, tax and total as strings with two
  decimals, for example `"12.50"`.
