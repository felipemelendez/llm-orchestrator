"""Receiving webhook events from the payment provider."""
import json


def parse_event(body):
    return json.loads(body.decode("utf-8"))
