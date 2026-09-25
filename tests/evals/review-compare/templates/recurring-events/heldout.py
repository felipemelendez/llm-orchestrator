"""Held-out check for recurring-events: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from datetime import date

sys.path.insert(0, ".")
from schedule.events import Event  # noqa: E402
from schedule.recurrence import Rule, RuleError  # noqa: E402

WIDE = (date(2025, 1, 1), date(2028, 12, 31))


def dates(rule, start, window=WIDE):
    return Event("E", start, rule).occurrences(*window)


def expect(error, call):
    try:
        call()
    except error:
        return
    raise AssertionError(f"expected {error.__name__}")


def check():
    assert dates(Rule("daily", until=date(2026, 4, 8)), date(2026, 4, 6)) == [
        date(2026, 4, 6), date(2026, 4, 7), date(2026, 4, 8)], "until is included"
    assert dates(Rule("daily", count=3, skip=frozenset({date(2026, 4, 7)})), date(2026, 4, 6)) == [
        date(2026, 4, 6), date(2026, 4, 8)], "count includes skipped dates"
    assert dates(Rule("weekly", weekdays=(0, 2), count=3), date(2026, 4, 8)) == [
        date(2026, 4, 8), date(2026, 4, 13), date(2026, 4, 15)], "nothing before the start"
    assert dates(Rule("weekly", interval=2, count=3), date(2026, 4, 6)) == [
        date(2026, 4, 6), date(2026, 4, 20), date(2026, 5, 4)], "every other week"
    assert dates(Rule("monthly", count=3), date(2026, 11, 15)) == [
        date(2026, 11, 15), date(2026, 12, 15), date(2027, 1, 15)], "months roll into the next year"
    assert dates(Rule("monthly", count=3), date(2026, 1, 31)) == [
        date(2026, 1, 31), date(2026, 3, 31), date(2026, 5, 31)], "short months are skipped"
    event = Event("E", date(2026, 4, 6), Rule("daily", count=5))
    assert event.occurrences(date(2026, 4, 7), date(2026, 4, 8)) == [
        date(2026, 4, 7), date(2026, 4, 8)], "the window start is included"
    event.cancel(date(2026, 4, 7))
    assert event.occurrences(date(2026, 4, 6), date(2026, 4, 8)) == [date(2026, 4, 6), date(2026, 4, 8)]
    expect(RuleError, lambda: Rule("daily", interval=0))
    expect(RuleError, lambda: Rule("daily", until=date(2026, 5, 1), count=3))
    daily = Event("E", date(2026, 4, 6), Rule("daily"))
    assert daily.next_occurrence(date(2026, 4, 10)) == date(2026, 4, 11), "strictly after"


if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(f"held-out check failed: {e!r}")
        sys.exit(1)
    print("held-out check passed")
