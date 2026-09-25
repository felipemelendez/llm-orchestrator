"""User accounts and their password hashes."""
import hashlib
import hmac
import os


def hash_password(password, salt=None):
    salt = salt or os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 100_000)
    return salt, digest


class UserStore:
    def __init__(self):
        self._users = {}

    def add(self, email, password):
        self._users[email.strip().lower()] = hash_password(password)

    def exists(self, email):
        return email.strip().lower() in self._users

    def check(self, email, password):
        record = self._users.get(email.strip().lower())
        if record is None:
            return False
        salt, digest = record
        return hmac.compare_digest(hash_password(password, salt)[1], digest)

    def set_password(self, email, password):
        self._users[email.strip().lower()] = hash_password(password)
