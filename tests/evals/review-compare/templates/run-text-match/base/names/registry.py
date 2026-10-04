"""Accounts kept in memory."""


class Registry:
    def __init__(self):
        self.users = {}

    def add(self, username, display_name):
        self.users[username] = {"display_name": display_name, "tags": []}
        return self.users[username]

    def get(self, username):
        return self.users.get(username)
