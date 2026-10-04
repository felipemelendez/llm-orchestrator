"""Held-out check for run-text-match: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
import unicodedata

sys.path.insert(0, ".")
from names.registry import BadUsername, Registry, Taken  # noqa: E402
from names.text import BadTag, is_reserved, normalize_name, parse_tags, valid_username  # noqa: E402


def raises(error, fn, *args):
    try:
        fn(*args)
    except error:
        return True
    except Exception as other:
        raise AssertionError(f"{args!r} raised {type(other).__name__}, not {error.__name__}")
    return False


def check():
    for name in ("alice", "Bob_99", "a" * 20):
        assert valid_username(name), f"{name!r} is a valid username"
    for name in ("alice\n", "bob\r\n", "bøb", "ab", "9lives", "a" * 21, "ali ce"):
        assert not valid_username(name), f"{name!r} is not a valid username"
    for name in ("admin", "Admin", "root7", "admin_2", "STAFF__01", "support_"):
        assert is_reserved(name), f"{name!r} is reserved"
    for name in ("administrator", "rooted", "alice", "sys_tem"):
        assert not is_reserved(name), f"{name!r} is not reserved"

    nfc = unicodedata.normalize("NFC", "José Núñez")
    nfd = unicodedata.normalize("NFD", "José Núñez")
    assert normalize_name(nfc) == normalize_name(nfd), "composed and decomposed accents match"
    assert normalize_name("Straße") == normalize_name("STRASSE"), "full case folding"
    assert normalize_name("  ann \t LEE ") == normalize_name("Ann Lee"), "spacing ignored"
    assert normalize_name("Ann Lee") != normalize_name("Anne Lee")

    registry = Registry()
    registry.add("jose", nfc)
    assert raises(Taken, registry.add, "jose2", nfd), "a decomposed copy of a display name is taken"
    registry.add("hans", "Hans Straße")
    assert raises(Taken, registry.add, "hans2", "HANS STRASSE"), "a case-folded copy is taken"
    assert raises(BadUsername, registry.add, "eve\n", "Eve"), "trailing newline username"
    assert raises(BadUsername, registry.add, "admin_2", "Not Admin"), "reserved with underscore"

    assert parse_tags('jam, "salt, pepper"') == ["jam", "salt, pepper"], "quoted tag after a space"
    assert parse_tags('"salt, pepper",jam, "a,b" ,x') == ["salt, pepper", "jam", "a,b", "x"]
    assert parse_tags("#News, news,  Big   Data ") == ["news", "big data"]
    assert parse_tags("") == [] and parse_tags(" , ,") == []
    for field in ("##news", "café", "tag, ٣", "#", "x, #, y", "naïve", "a" * 31):
        assert raises(BadTag, parse_tags, field), f"{field!r} must be rejected"

    registry.add("tagger", "Tag Person")
    registry.set_tags("tagger", "go")
    assert raises(BadTag, registry.set_tags, "tagger", "go, #"), "a lone # is rejected"
    assert registry.get("tagger")["tags"] == ["go"], "no tags stored after a rejected field"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
