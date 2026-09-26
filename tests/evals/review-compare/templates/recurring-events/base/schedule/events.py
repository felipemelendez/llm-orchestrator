"""Calendar events."""
from dataclasses import dataclass
from datetime import date


@dataclass
class Event:
    title: str
    start: date

    def occurrences(self, window_start, window_end):
        """The event's dates inside the window, both ends included."""
        if window_end < window_start:
            raise ValueError("the window ends before it starts")
        return [self.start] if window_start <= self.start <= window_end else []
