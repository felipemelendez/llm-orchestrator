"""Calendar events, which may repeat by a recurrence rule."""
from dataclasses import dataclass, field
from datetime import date, timedelta

from schedule.recurrence import Rule, expand

SEARCH_DAYS = 366 * 9


@dataclass
class Event:
    title: str
    start: date
    rule: Rule = None
    cancelled: set = field(default_factory=set)

    def occurrences(self, window_start, window_end):
        """The event's dates inside the window, both ends included."""
        if window_end < window_start:
            raise ValueError("the window ends before it starts")
        if self.rule is None:
            days = [self.start] if self.start <= window_end else []
        else:
            days = expand(self.rule, self.start, window_end)
        return [day for day in days if day >= window_start and day not in self.cancelled]

    def cancel(self, day):
        """Drop one occurrence; raise ValueError when the event does not fall on `day`."""
        if day not in self.occurrences(day, day):
            raise ValueError(f"{self.title} has no occurrence on {day}")
        self.cancelled.add(day)

    def next_occurrence(self, after):
        """The first occurrence strictly after `after`, or None."""
        upcoming = self.occurrences(after + timedelta(days=1), after + timedelta(days=SEARCH_DAYS))
        return upcoming[0] if upcoming else None
