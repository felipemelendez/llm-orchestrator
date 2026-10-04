"""Text rules for usernames, display names and tags."""
import csv
import re
import unicodedata

USERNAME = re.compile(r"[A-Za-z][A-Za-z0-9_]{2,19}")
RESERVED = {"admin", "root", "support", "system", "staff"}
MAX_TAG = 30
TAG_PUNCT = "-, "


class BadTag(ValueError):
    """A tag breaks the tag rules."""


def valid_username(name):
    return USERNAME.fullmatch(name) is not None


def is_reserved(name):
    base = name.casefold().rstrip("0123456789_")
    return base in RESERVED


def normalize_name(name):
    folded = unicodedata.normalize("NFC", name.casefold())
    return " ".join(folded.split())


def clean_tag(raw):
    tag = " ".join(raw.strip().removeprefix("#").split())
    if not tag or len(tag) > MAX_TAG:
        raise BadTag(raw)
    if not all(ch.isascii() and (ch.isalnum() or ch in TAG_PUNCT) for ch in tag):
        raise BadTag(raw)
    return tag.lower()


def parse_tags(field):
    entries = next(csv.reader([field], skipinitialspace=True), [])
    tags = []
    for raw in entries:
        if not raw.strip():
            continue
        tag = clean_tag(raw)
        if tag not in tags:
            tags.append(tag)
    return tags
