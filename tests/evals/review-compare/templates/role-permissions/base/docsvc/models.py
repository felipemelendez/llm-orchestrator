"""Data model for the document service."""
from dataclasses import dataclass


@dataclass(frozen=True)
class User:
    id: str
    org: str
    roles: frozenset = frozenset()


@dataclass
class Document:
    id: str
    owner_id: str
    org: str
    title: str
    body: str = ""
