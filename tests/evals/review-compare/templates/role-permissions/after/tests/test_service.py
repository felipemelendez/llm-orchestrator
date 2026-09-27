import unittest

from docsvc.models import User
from docsvc.service import DocumentService, NotFound, PermissionDenied

ANN = User("ann", "acme")
BOB = User("bob", "acme")
CAROL = User("carol", "acme", frozenset({"admin"}))
DAN = User("dan", "acme", frozenset({"viewer"}))


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.service = DocumentService()
        self.doc = self.service.create(ANN, "Plan")

    def test_create_and_get(self):
        self.assertEqual(self.service.get(ANN, self.doc.id).title, "Plan")
        self.assertEqual(self.doc.owner_id, "ann")

    def test_unknown_document(self):
        with self.assertRaises(NotFound):
            self.service.get(ANN, "doc-99")

    def test_owner_can_edit_and_delete(self):
        self.service.update(ANN, self.doc.id, "v2")
        self.assertEqual(self.doc.body, "v2")
        self.service.delete(ANN, self.doc.id)
        self.assertEqual(self.service.list_readable(ANN), [])

    def test_stranger_cannot_read(self):
        with self.assertRaises(PermissionDenied):
            self.service.get(BOB, self.doc.id)

    def test_shared_user_can_read(self):
        self.service.share(ANN, self.doc.id, BOB, "view")
        self.assertEqual(self.service.get(BOB, self.doc.id).id, self.doc.id)

    def test_shared_editor_can_edit(self):
        self.service.share(ANN, self.doc.id, BOB, "edit")
        self.service.update(BOB, self.doc.id, "from bob")
        self.assertEqual(self.doc.body, "from bob")

    def test_only_owner_shares(self):
        with self.assertRaises(PermissionDenied):
            self.service.share(BOB, self.doc.id, DAN, "view")

    def test_org_admin_can_edit(self):
        self.service.update(CAROL, self.doc.id, "admin edit")
        self.assertEqual(self.doc.body, "admin edit")

    def test_org_visible_document_is_read_only_for_viewers(self):
        doc = self.service.create(ANN, "Handbook", org_visible=True)
        self.assertEqual(self.service.get(DAN, doc.id).title, "Handbook")
        with self.assertRaises(PermissionDenied):
            self.service.update(DAN, doc.id, "vandalism")

    def test_unshare(self):
        self.service.share(ANN, self.doc.id, BOB, "view")
        self.service.unshare(ANN, self.doc.id, BOB)
        with self.assertRaises(PermissionDenied):
            self.service.get(BOB, self.doc.id)

    def test_list_readable(self):
        second = self.service.create(ANN, "Notes")
        self.assertEqual([d.id for d in self.service.list_readable(ANN)], [self.doc.id, second.id])
        self.assertEqual(self.service.list_readable(BOB), [])


if __name__ == "__main__":
    unittest.main()
