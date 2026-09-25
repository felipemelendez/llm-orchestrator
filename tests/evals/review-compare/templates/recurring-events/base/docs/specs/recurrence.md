# Repeating events

- A `Rule` repeats an event `daily`, `weekly` or `monthly`, every
  `interval` periods (at least 1).
- A weekly rule may list `weekdays` (0 is Monday); without them it repeats
  on the start date's weekday. No occurrence is ever before the start date.
- A monthly rule repeats on the start date's day of the month. A month too
  short for that day (for example the 31st in April) has no occurrence; the
  date is never moved to the month's last day.
- A rule ends at `until` (that date included) or after `count` occurrences,
  not both. `count` counts dates in `skip` too, so skipping a date does not
  add one at the end.
- `Event.occurrences(window_start, window_end)` lists dates inside the window,
  both ends included, minus cancelled dates. `cancel(day)` removes one
  occurrence. `next_occurrence(after)` is the first occurrence strictly after
  `after`.
