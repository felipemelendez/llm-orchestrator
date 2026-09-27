import tempfile
import unittest
from pathlib import Path

from files.storage import save


class SaveTest(unittest.TestCase):
    def test_saves_into_user_folder(self):
        with tempfile.TemporaryDirectory() as storage:
            path = save(storage, "bob", "notes.txt", b"hi")
            self.assertEqual(path, Path(storage) / "bob" / "notes.txt")
            self.assertEqual(path.read_bytes(), b"hi")


if __name__ == "__main__":
    unittest.main()
