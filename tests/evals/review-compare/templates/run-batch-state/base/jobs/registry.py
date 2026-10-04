"""Job handlers registered by name, each with its default options."""


class UnknownJob(KeyError):
    """No handler is registered under this name."""


class Registry:
    def __init__(self):
        self._handlers = {}

    def register(self, name, handler, defaults=None):
        if not name:
            raise ValueError("a job needs a name")
        self._handlers[name] = (handler, defaults if defaults is not None else {})

    def get(self, name):
        try:
            return self._handlers[name]
        except KeyError:
            raise UnknownJob(name) from None

    def defaults(self, name):
        return self.get(name)[1]

    def names(self):
        return sorted(self._handlers)
