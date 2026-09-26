import unittest

from webhooks.receiver import InvalidSignature, Receiver, parse_event, sign

BODY = b'{"id": "evt_1", "type": "charge.paid"}'


def headers(secret, timestamp, body=BODY):
    return {"X-Signature": f"t={timestamp},v1={sign(secret, timestamp, body)}"}


class ParseEventTest(unittest.TestCase):
    def test_parses_json_body(self):
        self.assertEqual(parse_event(b'{"id": "evt_1"}'), {"id": "evt_1"})


class VerifyTest(unittest.TestCase):
    def test_accepts_valid_signature(self):
        receiver = Receiver(["whsec_a"])
        event = receiver.verify(headers("whsec_a", 1000), BODY, now=1010)
        self.assertEqual(event["type"], "charge.paid")

    def test_rejects_wrong_secret(self):
        receiver = Receiver(["whsec_a"])
        with self.assertRaises(InvalidSignature):
            receiver.verify(headers("whsec_b", 1000), BODY, now=1000)

    def test_rejects_stale_timestamp(self):
        receiver = Receiver(["whsec_a"])
        with self.assertRaises(InvalidSignature):
            receiver.verify(headers("whsec_a", 1000), BODY, now=5000)

    def test_rejects_missing_header(self):
        receiver = Receiver(["whsec_a"])
        with self.assertRaises(InvalidSignature):
            receiver.verify({}, BODY, now=1000)

    def test_rejects_tampered_body(self):
        receiver = Receiver(["whsec_a"])
        with self.assertRaises(InvalidSignature):
            receiver.verify(headers("whsec_a", 1000), BODY + b" ", now=1000)


if __name__ == "__main__":
    unittest.main()
