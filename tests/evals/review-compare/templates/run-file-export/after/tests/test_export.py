import gzip
import os
import tempfile
import unittest

from exporter import export


def write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


class ExportNameTest(unittest.TestCase):
    def test_prefix_removed(self):
        self.assertEqual(export.export_name("draft-plan.txt"), "plan.txt")

    def test_extension_renamed(self):
        self.assertEqual(export.export_name("photo.jpeg"), "photo.jpg")
        self.assertEqual(export.export_name("notes.txt"), "notes.txt")


class ExportFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.source = os.path.join(self.tmp.name, "source")
        self.out = os.path.join(self.tmp.name, "out")
        write(os.path.join(self.source, "notes.txt"), b"hello")
        write(os.path.join(self.source, "photo.jpeg"))
        write(os.path.join(self.source, "draft-plan.txt"))
        write(os.path.join(self.source, "sub", "summary.md"))
        write(os.path.join(self.source, ".hidden"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_exports_and_lists(self):
        result = export.export_files(self.source, self.out)
        self.assertEqual(result, ["notes.txt", "photo.jpg", "plan.txt", "summary.md"])
        self.assertEqual(sorted(os.listdir(self.out)), result)

    def test_user_chosen_name(self):
        result = export.export_files(self.source, self.out, names={"notes.txt": "kept.txt"})
        self.assertIn("kept.txt", result)
        with open(os.path.join(self.out, "kept.txt"), "rb") as f:
            self.assertEqual(f.read(), b"hello")

    def test_compress(self):
        result = export.export_files(self.source, self.out, compress=True)
        self.assertIn("notes.txt.gz", result)
        self.assertFalse(os.path.exists(os.path.join(self.out, "notes.txt")))
        with gzip.open(os.path.join(self.out, "notes.txt.gz")) as f:
            self.assertEqual(f.read(), b"hello")


if __name__ == "__main__":
    unittest.main()
