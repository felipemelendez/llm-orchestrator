import unittest

import importer


class PackageTest(unittest.TestCase):
    def test_imports(self):
        self.assertIn("import", importer.__doc__)


if __name__ == "__main__":
    unittest.main()
