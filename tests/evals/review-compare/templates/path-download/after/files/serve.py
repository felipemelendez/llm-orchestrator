"""Serve files that users uploaded to their own folder."""
from pathlib import Path

MAX_BYTES = 10 * 1024 * 1024
TYPES = {
    ".txt": "text/plain; charset=utf-8",
    ".csv": "text/csv; charset=utf-8",
    ".pdf": "application/pdf",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
}
INLINE = {".txt", ".csv", ".png", ".jpg", ".jpeg"}
FALLBACK = "application/octet-stream"


class NotFound(Exception):
    """No such file in the user's folder."""


class Forbidden(Exception):
    """The request names something outside the user's folder."""


class TooLarge(Exception):
    """The file is over MAX_BYTES."""


def user_root(storage, user_id):
    if not user_id.isalnum():
        raise Forbidden(user_id)
    return (Path(storage) / user_id).resolve()


def resolve(storage, user_id, name):
    root = user_root(storage, user_id)
    if not name or "\x00" in name:
        raise Forbidden(name)
    path = (root / name).resolve()
    if not path.is_relative_to(root) or path == root:
        raise Forbidden(name)
    if not path.is_file():
        raise NotFound(name)
    return path


def content_type(path):
    return TYPES.get(path.suffix.lower(), FALLBACK)


def disposition(path):
    kind = "inline" if path.suffix.lower() in INLINE else "attachment"
    safe = path.name.replace('"', "")
    return f'{kind}; filename="{safe}"'


def download(storage, user_id, name):
    path = resolve(storage, user_id, name)
    if path.stat().st_size > MAX_BYTES:
        raise TooLarge(name)
    return {
        "body": path.read_bytes(),
        "content_type": content_type(path),
        "disposition": disposition(path),
    }
