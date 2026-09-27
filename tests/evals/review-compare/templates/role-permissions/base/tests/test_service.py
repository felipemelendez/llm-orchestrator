import unittest

from docsvc.models import User
from docsvc.service import DocumentService


class ServiceTest(unittest.TestCase):
    def test_create_and_get(self):
        service = DocumentService()
        doc = service.create(User("ann", "acme"), "Plan")
        self.assertEqual(service.get(doc.id).title, "Plan")
        self.assertEqual(doc.owner_id, "ann")


if __name__ == "__main__":
    unittest.main()
