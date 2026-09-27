import unittest

from api.listing import InvalidCursor, list_items, list_page

ITEMS = [{"id": 3, "status": "open"}, {"id": 1, "status": "closed"}, {"id": 2, "status": "open"}]


class ListItemsTest(unittest.TestCase):
    def test_ordered_by_id(self):
        self.assertEqual([item["id"] for item in list_items(ITEMS)], [1, 2, 3])

    def test_filters_by_status(self):
        self.assertEqual([item["id"] for item in list_items(ITEMS, "open")], [2, 3])


class ListPageTest(unittest.TestCase):
    def test_first_page(self):
        page = list_page(ITEMS, limit=2)
        self.assertEqual([item["id"] for item in page["items"]], [1, 2])
        self.assertIsNotNone(page["next_cursor"])

    def test_invalid_cursor(self):
        with self.assertRaises(InvalidCursor):
            list_page(ITEMS, cursor="not-a-cursor")


if __name__ == "__main__":
    unittest.main()
