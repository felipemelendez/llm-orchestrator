"""Receiving webhook events from the payment provider."""
import hashlib
import hmac
import json

DEFAULT_TOLERANCE = 300


class InvalidSignature(Exception):
    """The request is not signed by a current secret."""


class ReplayedEvent(Exception):
    """This event id was already accepted."""


def parse_event(body):
    return json.loads(body.decode("utf-8"))


def parse_header(header):
    timestamp, signatures = None, []
    for part in header.split(","):
        key, sep, value = part.strip().partition("=")
        if not sep:
            raise InvalidSignature("malformed signature header")
        if key == "t":
            try:
                timestamp = int(value)
            except ValueError:
                raise InvalidSignature("malformed timestamp") from None
        elif key == "v1":
            signatures.append(value)
    if timestamp is None or not signatures:
        raise InvalidSignature("the signature header needs t and v1")
    return timestamp, signatures


def sign(secret, timestamp, body):
    payload = f"{timestamp}.".encode() + body
    return hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()


class Receiver:
    def __init__(self, secrets, tolerance=DEFAULT_TOLERANCE):
        if not secrets:
            raise ValueError("at least one secret is required")
        self.secrets = list(secrets)
        self.tolerance = tolerance
        self._seen = {}

    def verify(self, headers, body, now):
        header = headers.get("X-Signature")
        if not header:
            raise InvalidSignature("missing signature header")
        timestamp, signatures = parse_header(header)
        if abs(now - timestamp) > self.tolerance:
            raise InvalidSignature("timestamp outside the tolerance window")
        expected = [sign(secret, timestamp, body) for secret in self.secrets]
        if not any(hmac.compare_digest(e, s) for e in expected for s in signatures):
            raise InvalidSignature("no signature matches")
        event = parse_event(body)
        self._forget_before(now - self.tolerance)
        if event["id"] in self._seen:
            raise ReplayedEvent(event["id"])
        self._seen[event["id"]] = timestamp
        return event

    def _forget_before(self, cutoff):
        for event_id, seen_at in list(self._seen.items()):
            if seen_at < cutoff:
                del self._seen[event_id]
