import os
import unittest

from exporter.library import user_folder


class UserFolderTest(unittest.TestCase):
    def test_folder_under_root(self):
        self.assertEqual(user_folder("/data", "bob"), os.path.join("/data", "users", "bob", "files"))

    def test_bad_user_id(self):
        with self.assertRaises(ValueError):
            user_folder("/data", "../alice")


if __name__ == "__main__":
    unittest.main()
