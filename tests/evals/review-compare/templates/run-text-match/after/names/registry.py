"""Accounts kept in memory."""
from names.text import is_reserved, normalize_name, parse_tags, valid_username


class BadUsername(ValueError):
    """The username breaks the username rules or is reserved."""


class Taken(ValueError):
    """The username or display name is already used."""


class Registry:
    def __init__(self):
        self.users = {}
        self.name_keys = {}

    def add(self, username, display_name):
        if not valid_username(username) or is_reserved(username):
            raise BadUsername(username)
        if any(existing.casefold() == username.casefold() for existing in self.users):
            raise Taken(username)
        key = normalize_name(display_name)
        if key in self.name_keys:
            raise Taken(display_name)
        self.name_keys[key] = username
        self.users[username] = {"display_name": display_name, "tags": []}
        return self.users[username]

    def get(self, username):
        return self.users.get(username)

    def set_tags(self, username, field):
        tags = parse_tags(field)
        self.users[username]["tags"] = tags
        return tags
