"""Held-out check for password-reset: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import itertools
import sys
from datetime import datetime, timedelta

sys.path.insert(0, ".")
from accounts.reset import RateLimited, ResetError, ResetService  # noqa: E402
from accounts.users import UserStore  # noqa: E402


class Clock:
    def __init__(self):
        self.now = datetime(2026, 5, 1, 9, 0)

    def __call__(self):
        return self.now


def setup():
    users = UserStore()
    users.add("ann@example.com", "old password 1")
    clock = Clock()
    counter = itertools.count(1)
    return users, clock, ResetService(users, clock, new_token=lambda: f"token-{next(counter)}")


def expect(error, call):
    try:
        call()
    except error:
        return
    raise AssertionError(f"expected {error.__name__}")


def check():
    users, clock, service = setup()
    token = service.request("ann@example.com")
    service.redeem(token, "a new long password")
    expect(ResetError, lambda: service.redeem(token, "another long password"))

    users, clock, service = setup()
    token = service.request("ann@example.com")
    clock.now += timedelta(hours=1)
    expect(ResetError, lambda: service.redeem(token, "a new long password"))

    users, clock, service = setup()
    first = service.request("ann@example.com")
    service.request("ann@example.com")
    expect(ResetError, lambda: service.redeem(first, "a new long password"))

    users, clock, service = setup()
    for _ in range(3):
        service.request("ann@example.com")
    expect(RateLimited, lambda: service.request("ann@example.com"))

    users, clock, service = setup()
    for _ in range(3):
        assert service.request("nobody@example.com") is None
    expect(RateLimited, lambda: service.request("nobody@example.com"))

    users, clock, service = setup()
    for email in ("Ann@example.com", "ann@EXAMPLE.com", "ANN@example.com"):
        service.request(email)
    expect(RateLimited, lambda: service.request("ann@example.com"))

    users, clock, service = setup()
    token = service.request("ann@example.com")
    expect(ResetError, lambda: service.redeem(token, "x" * 11))
    expect(ResetError, lambda: service.redeem(token, "x" * 7))
    assert service.redeem(token, "x" * 12) == "ann@example.com", "a rejected password keeps the token"

    users, clock, service = setup()
    for _ in range(3):
        service.request("ann@example.com")
    clock.now += timedelta(hours=1)
    assert service.request("ann@example.com") is not None, "a request one hour old no longer counts"

    users, clock, service = setup()
    token = service.request("ann@example.com")
    clock.now += timedelta(minutes=59)
    service.redeem(token, "a new long password")
    assert users.check("ann@example.com", "a new long password")


if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(f"held-out check failed: {e!r}")
        sys.exit(1)
    print("held-out check passed")
