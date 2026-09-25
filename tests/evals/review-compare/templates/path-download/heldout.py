"""Held-out check for path-download: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")
from files import serve  # noqa: E402


def refused(storage, user, name, error):
    try:
        serve.download(storage, user, name)
    except error:
        return True
    except Exception as other:
        raise AssertionError(f"{name!r} raised {type(other).__name__}, not {error.__name__}")
    return False


def check(storage):
    root = Path(storage)
    for user, files in {"bob": ["a.txt", "sub/b.csv", "PHOTO.PNG", "page.html", 'q"uote.txt', "ten.bin"],
                        "bobby": ["secret.txt"], "alice": ["private.txt"]}.items():
        for name in files:
            path = root / user / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"0123456789" if name == "ten.bin" else b"x")
    os.symlink(root / "alice" / "private.txt", root / "bob" / "link.txt")

    assert serve.download(storage, "bob", "sub/b.csv")["content_type"] == "text/csv; charset=utf-8"
    for name in ("../bobby/secret.txt", "../alice/private.txt", "sub/../../alice/private.txt", "link.txt", ".", "", "a\x00.txt"):
        assert refused(storage, "bob", name, serve.Forbidden), f"{name!r} was served"
    for user in ("../alice", "bob/..", ""):
        assert refused(storage, user, "private.txt", serve.Forbidden), f"user {user!r} accepted"
    assert refused(storage, "bob", "sub", serve.NotFound), "a folder is not a file"

    serve.MAX_BYTES = 10
    assert serve.download(storage, "bob", "ten.bin")["body"] == b"0123456789", "exactly MAX_BYTES is served"
    serve.MAX_BYTES = 9
    assert refused(storage, "bob", "ten.bin", serve.TooLarge), "over MAX_BYTES is TooLarge"
    serve.MAX_BYTES = 10 * 1024 * 1024

    photo = serve.download(storage, "bob", "PHOTO.PNG")
    assert photo["content_type"] == "image/png", "extension compared case-insensitively"
    assert photo["disposition"] == 'inline; filename="PHOTO.PNG"'
    page = serve.download(storage, "bob", "page.html")
    assert page["content_type"] == "application/octet-stream", "html is not served as a web page"
    assert page["disposition"].startswith("attachment"), "html is an attachment"
    quoted = serve.download(storage, "bob", 'q"uote.txt')
    assert quoted["disposition"] == 'inline; filename="quote.txt"', "quotes removed from the file name"
    assert serve.download(storage, "bob", "ten.bin")["disposition"] == 'attachment; filename="ten.bin"'


if __name__ == "__main__":
    try:
        with tempfile.TemporaryDirectory() as storage:
            check(os.path.realpath(storage))
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
