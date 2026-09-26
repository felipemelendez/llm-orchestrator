# Business days

- `BusinessCalendar(holidays=(), observe_weekend_holidays=True)`. A business
  day is a weekday that is not a holiday.
- With `observe_weekend_holidays`, a holiday on a Saturday is observed on the
  Friday before it and a holiday on a Sunday on the Monday after it; the
  observed day is the holiday. Without it, holidays are used as given.
- `next_business_day(day)` is the first business day strictly after `day`.
- `add_business_days(start, count)` moves `count` business days from `start`:
  forward when `count` is positive, backward when negative, and returns
  `start` itself when `count` is 0. Only business days are counted, so
  holidays and weekends are skipped.
- `business_days_between(start, end)` counts the business days in
  `[start, end)`: `start` counts, `end` does not. When `end` is before
  `start`, it is the negative of `business_days_between(end, start)`.
