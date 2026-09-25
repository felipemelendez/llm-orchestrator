"""Single-use password reset tokens."""
import hashlib
import secrets
from datetime import timedelta

TOKEN_TTL = timedelta(hours=1)
MAX_REQUESTS = 3
REQUEST_WINDOW = timedelta(hours=1)
MIN_PASSWORD_LENGTH = 12


class ResetError(Exception):
    """The token is unknown, used or expired, or the new password is not allowed."""


class RateLimited(Exception):
    """Too many reset requests for one address in the request window."""


def _digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


class ResetService:
    def __init__(self, users, clock, new_token=None):
        self._users = users
        self._clock = clock
        self._new_token = new_token or (lambda: secrets.token_urlsafe(32))
        self._tokens = {}
        self._requests = {}

    def request(self, email):
        """Issue a reset token for `email`, or return None when there is no such user."""
        email = email.strip().lower()
        now = self._clock()
        recent = [t for t in self._requests.get(email, []) if now - t < REQUEST_WINDOW]
        if len(recent) >= MAX_REQUESTS:
            raise RateLimited(email)
        recent.append(now)
        self._requests[email] = recent
        if not self._users.exists(email):
            return None
        for digest, entry in list(self._tokens.items()):
            if entry["email"] == email:
                del self._tokens[digest]
        token = self._new_token()
        self._tokens[_digest(token)] = {"email": email, "expires_at": now + TOKEN_TTL}
        return token

    def redeem(self, token, new_password):
        """Set a new password with a valid token; return the account's email."""
        entry = self._tokens.get(_digest(token))
        if entry is None:
            raise ResetError("unknown or used token")
        if self._clock() >= entry["expires_at"]:
            del self._tokens[_digest(token)]
            raise ResetError("token expired")
        if len(new_password) < MIN_PASSWORD_LENGTH:
            raise ResetError(f"passwords need at least {MIN_PASSWORD_LENGTH} characters")
        del self._tokens[_digest(token)]
        self._users.set_password(entry["email"], new_password)
        return entry["email"]
