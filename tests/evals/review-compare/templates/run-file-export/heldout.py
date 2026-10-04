"""Held-out check for run-file-export: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import gzip
import os
import sys
import tempfile

sys.path.insert(0, ".")
from exporter import export  # noqa: E402


def write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def check(tmp):
    source = os.path.join(tmp, "my files")
    out = os.path.join(tmp, "export dir", "nested")
    outside = os.path.join(tmp, "outside")
    os.makedirs(outside)
    for name in ("data.csv", "trend.txt", "draft-a.txt", "photo.v2.jpeg", "IMG.JPEG",
                 "sub/deep.txt", ".env", ".git/config", "sub/.cache/blob.txt", "real.txt"):
        write(os.path.join(source, name))
    write(os.path.join(tmp, "secret.txt"), b"secret")
    os.symlink(os.path.join(tmp, "secret.txt"), os.path.join(source, "link.txt"))
    os.symlink(outside, os.path.join(source, "linkdir"))
    write(os.path.join(outside, "inside-link.txt"))

    names = {"real.txt": os.path.join(outside, "stolen.txt"), "trend.txt": "../../up.txt"}
    result = export.export_files(source, out, names=names)
    expected = ["IMG.jpg", "a.txt", "data.csv", "deep.txt", "photo.v2.jpg", "stolen.txt", "up.txt"]
    assert result == expected, f"exported {result}, expected {expected}"
    assert sorted(os.listdir(out)) == expected, f"export folder holds {sorted(os.listdir(out))}"
    assert not os.path.exists(os.path.join(outside, "stolen.txt")), "wrote outside the export folder"
    assert not os.path.exists(os.path.join(tmp, "export dir", "up.txt")), "wrote outside the export folder"

    assert export.export_name("data.csv") == "data.csv", "only the draft- prefix is removed"
    assert export.export_name("draft-tar.tar.gz") == "tar.tar.gz"
    assert export.export_name("page.v1.HTM") == "page.v1.html", "only the last extension changes"

    zipped = os.path.join(tmp, "zipped out")
    big = b"abc" * 20000
    write(os.path.join(tmp, "zip source", "big notes.txt"), big)
    result = export.export_files(os.path.join(tmp, "zip source"), zipped, compress=True)
    assert result == ["big notes.txt.gz"], f"compressed export listed {result}"
    with gzip.open(os.path.join(zipped, "big notes.txt.gz")) as f:
        assert f.read() == big, "compressed content round-trips"
    assert os.path.getsize(os.path.join(zipped, "big notes.txt.gz")) < len(big) // 10, "default level compresses"

    stored = os.path.join(tmp, "stored")
    export.export_files(os.path.join(tmp, "zip source"), stored, compress=True, level=0)
    size = os.path.getsize(os.path.join(stored, "big notes.txt.gz"))
    assert size > len(big), f"level 0 stores without compressing ({size} bytes for {len(big)})"

    empty = os.path.join(tmp, "empty")
    os.makedirs(empty)
    target = os.path.join(tmp, "fresh", "a", "b")
    assert export.export_files(empty, target) == [], "an empty folder exports nothing"
    assert os.path.isdir(target), "the export folder is created even when nothing is exported"

    try:
        export.export_files(os.path.join(tmp, "missing"), os.path.join(tmp, "x"))
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("a missing source folder is FileNotFoundError")


if __name__ == "__main__":
    try:
        with tempfile.TemporaryDirectory() as tmp:
            check(os.path.realpath(tmp))
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
