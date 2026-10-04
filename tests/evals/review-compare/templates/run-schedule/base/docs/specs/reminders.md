# Remind users before a subscription charges them

Add `subs/schedule.py` and three optional fields on `Subscription`:
`days_before` (default `None`), `tz` (an IANA time zone name, default
`"UTC"`) and `remind_time` (a `datetime.time`, default 09:00).

- `parse_timestamp(text)` reads an ISO 8601 timestamp such as
  `2024-03-01T10:00:00Z` or `2024-03-01T12:00:00.250+02:00`. It must carry an
  offset or a trailing `Z`; one without is a `ValueError`. Fractional
  seconds are allowed. The result is the same moment as an aware datetime in
  UTC.
- `add_months(day, months)` returns the same day of the month `months`
  later, or the last day of that month when it is shorter. It works across
  year ends.
- `billing_dates(sub)` yields the charge dates in order, starting with
  `sub.start`. A monthly plan charges every month and a yearly plan every
  year, each charge counted from the start date: a plan started on 31
  January charges on 29 February in 2024 and again on 31 March. A yearly plan
  started on 29 February charges on 28 February in years that have no 29th.
- `reminder_at(sub, bills_on)` is the moment to remind the user about the
  charge on `bills_on`: `remind_time` on the user's wall clock, in `tz`,
  `days_before` calendar days before the charge, returned in UTC. When
  `days_before` is `None` it is 3; 0 means the morning of the charge itself.
  The reminder stays at `remind_time` local time even when a daylight saving
  change falls between the reminder and the charge.
- `upcoming(subs, now, days)` lists a `Reminder(name, bills_on, at)` for
  every reminder from `now` (included) up to exactly `days` times 24 hours
  after `now` (excluded), soonest first, ties ordered by name. `now` may be
  aware or naive; a naive `now` means UTC, whatever the computer's own time
  zone is.
