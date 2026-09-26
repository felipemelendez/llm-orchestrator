import unittest

from webhooks.receiver import parse_event


class ParseEventTest(unittest.TestCase):
    def test_parses_json_body(self):
        self.assertEqual(parse_event(b'{"id": "evt_1"}'), {"id": "evt_1"})


if __name__ == "__main__":
    unittest.main()
