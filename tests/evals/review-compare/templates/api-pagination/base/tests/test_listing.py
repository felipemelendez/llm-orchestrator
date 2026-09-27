import unittest

from api.listing import list_items

ITEMS = [{"id": 3, "status": "open"}, {"id": 1, "status": "closed"}, {"id": 2, "status": "open"}]


class ListItemsTest(unittest.TestCase):
    def test_ordered_by_id(self):
        self.assertEqual([item["id"] for item in list_items(ITEMS)], [1, 2, 3])

    def test_filters_by_status(self):
        self.assertEqual([item["id"] for item in list_items(ITEMS, "open")], [2, 3])


if __name__ == "__main__":
    unittest.main()
