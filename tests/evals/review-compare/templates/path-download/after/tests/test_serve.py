import tempfile
import unittest
from unittest import mock

from files import serve
from files.storage import save


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.storage = self.tmp.name
        save(self.storage, "bob", "notes.txt", b"hello")
        save(self.storage, "bob", "report.pdf", b"%PDF")

    def tearDown(self):
        self.tmp.cleanup()

    def test_text_file_inline(self):
        result = serve.download(self.storage, "bob", "notes.txt")
        self.assertEqual(result["body"], b"hello")
        self.assertEqual(result["content_type"], "text/plain; charset=utf-8")
        self.assertEqual(result["disposition"], 'inline; filename="notes.txt"')

    def test_pdf_attachment(self):
        result = serve.download(self.storage, "bob", "report.pdf")
        self.assertEqual(result["content_type"], "application/pdf")
        self.assertTrue(result["disposition"].startswith("attachment"))

    def test_absolute_path_forbidden(self):
        with self.assertRaises(serve.Forbidden):
            serve.download(self.storage, "bob", "/etc/passwd")

    def test_missing_file(self):
        with self.assertRaises(serve.NotFound):
            serve.download(self.storage, "bob", "nope.txt")

    def test_too_large(self):
        with mock.patch.object(serve, "MAX_BYTES", 4):
            with self.assertRaises(serve.TooLarge):
                serve.download(self.storage, "bob", "notes.txt")


if __name__ == "__main__":
    unittest.main()
