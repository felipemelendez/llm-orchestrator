"""Held-out check for webhook-signature: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import hashlib
import hmac
import sys

sys.path.insert(0, ".")
from webhooks.receiver import InvalidSignature, Receiver, ReplayedEvent  # noqa: E402


def signature(secret, t, body):
    return hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()


def body(event_id):
    return ('{"id": "%s"}' % event_id).encode()


def header(t, *sigs):
    return {"X-Signature": ",".join([f"t={t}"] + [f"v1={s}" for s in sigs])}


def rejected(receiver, headers, raw, now, error=InvalidSignature):
    try:
        receiver.verify(headers, raw, now)
    except error:
        return True
    return False


def check():
    r = Receiver(["old", "new"])
    b = body("e1")
    assert r.verify(header(1000, signature("new", 1000, b)), b, 1000)["id"] == "e1", "second secret accepted"
    b = body("e2")
    assert r.verify(header(1000, "deadbeef", signature("old", 1000, b)), b, 1000), "any v1 may match"
    b = body("e3")
    assert r.verify(header(1000, signature("old", 1000, b)), b, 1300), "exactly tolerance is accepted"
    b = body("e4")
    assert rejected(r, header(1000, signature("old", 1000, b)), b, 1301), "past tolerance is rejected"
    assert rejected(r, header(1400, signature("old", 1400, b)), b, 1000), "future timestamps are rejected"
    assert rejected(Receiver(["old"]), {}, b, 1000), "a missing header is rejected"
    assert rejected(r, {"X-Signature": f"t=1000,v1={signature('old', 1000, b)},junk"}, b, 1000), \
        "a malformed part is rejected"
    assert rejected(r, header(1000, hmac.new(b"old", b, hashlib.sha256).hexdigest()), b, 1000), \
        "the timestamp is part of the signed payload"

    r = Receiver(["s"])
    b = body("dup")
    r.verify(header(1000, signature("s", 1000, b)), b, 1000)
    assert rejected(r, header(1000, signature("s", 1000, b)), b, 1005, ReplayedEvent), "exact replay"
    assert rejected(r, header(1100, signature("s", 1100, b)), b, 1100, ReplayedEvent), "replay with a new t"

    try:
        Receiver([])
    except ValueError:
        pass
    else:
        raise AssertionError("an empty secret list is accepted")


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
