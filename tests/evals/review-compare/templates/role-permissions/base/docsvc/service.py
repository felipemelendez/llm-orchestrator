"""Storage and operations for documents."""
from .models import Document


class DocumentService:
    def __init__(self):
        self._docs = {}
        self._next = 1

    def create(self, user, title, body=""):
        doc = Document(f"doc-{self._next}", user.id, user.org, title, body)
        self._next += 1
        self._docs[doc.id] = doc
        return doc

    def get(self, doc_id):
        return self._docs[doc_id]
