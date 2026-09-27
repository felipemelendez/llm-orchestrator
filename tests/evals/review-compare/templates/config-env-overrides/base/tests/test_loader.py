import json
import os
import tempfile
import unittest

from config.loader import load


class LoadTest(unittest.TestCase):
    def test_reads_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "app.json")
            with open(path, "w") as handle:
                json.dump({"port": 9000}, handle)
            self.assertEqual(load(path), {"port": 9000})


if __name__ == "__main__":
    unittest.main()
