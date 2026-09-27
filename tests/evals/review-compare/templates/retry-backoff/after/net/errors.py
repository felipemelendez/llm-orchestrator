"""Errors raised by the service clients."""


class TransientError(Exception):
    """A failure worth retrying, such as a timeout or a 503."""


class PermanentError(Exception):
    """A failure that will not go away on its own, such as a 400."""


def classify(status):
    """The error class for an HTTP status, or None for a success."""
    if status < 400:
        return None
    if status in (408, 429) or status >= 500:
        return TransientError
    return PermanentError
