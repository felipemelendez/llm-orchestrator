"""Data model for the document service."""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class User:
    id: str
    org: str
    roles: frozenset = frozenset()
    suspended: bool = False


@dataclass
class Document:
    id: str
    owner_id: str
    org: str
    title: str
    body: str = ""
    org_visible: bool = False
    archived: bool = False
    shares: dict = field(default_factory=dict)
