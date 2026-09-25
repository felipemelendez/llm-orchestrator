"""Storage and operations for documents."""
from . import permissions
from .models import Document


class NotFound(KeyError):
    """No document has this id."""


class PermissionDenied(Exception):
    """The user may not do this to the document."""


class DocumentService:
    def __init__(self):
        self._docs = {}
        self._next = 1

    def create(self, user, title, body="", org_visible=False):
        if user.suspended:
            raise PermissionDenied(f"{user.id} is suspended")
        doc = Document(f"doc-{self._next}", user.id, user.org, title, body, org_visible=org_visible)
        self._next += 1
        self._docs[doc.id] = doc
        return doc

    def _find(self, doc_id):
        try:
            return self._docs[doc_id]
        except KeyError:
            raise NotFound(doc_id) from None

    def get(self, user, doc_id):
        doc = self._find(doc_id)
        if not permissions.can_read(user, doc):
            raise PermissionDenied(f"{user.id} may not read {doc_id}")
        return doc

    def update(self, user, doc_id, body):
        doc = self._find(doc_id)
        if not permissions.can_edit(user, doc):
            raise PermissionDenied(f"{user.id} may not edit {doc_id}")
        doc.body = body
        return doc

    def archive(self, user, doc_id):
        doc = self._find(doc_id)
        if not permissions.can_delete(user, doc):
            raise PermissionDenied(f"{user.id} may not archive {doc_id}")
        doc.archived = True
        return doc

    def delete(self, user, doc_id):
        doc = self._find(doc_id)
        if not permissions.can_delete(user, doc):
            raise PermissionDenied(f"{user.id} may not delete {doc_id}")
        del self._docs[doc_id]

    def share(self, user, doc_id, target, level):
        doc = self._find(doc_id)
        if not permissions.can_share(user, doc, target, level):
            raise PermissionDenied(f"{user.id} may not share {doc_id} with {target.id}")
        doc.shares[target.id] = level

    def unshare(self, user, doc_id, target):
        doc = self._find(doc_id)
        if not permissions.can_share(user, doc, target, permissions.VIEW):
            raise PermissionDenied(f"{user.id} may not change sharing on {doc_id}")
        doc.shares.pop(target.id, None)

    def list_readable(self, user):
        readable = (doc for doc in self._docs.values() if permissions.can_read(user, doc))
        return sorted(readable, key=lambda doc: doc.id)
