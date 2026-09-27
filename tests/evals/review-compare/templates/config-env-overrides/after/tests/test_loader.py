import json
import os
import tempfile
import unittest

from config.loader import ConfigError, load


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, data):
        path = os.path.join(self.tmp.name, "app.json")
        with open(path, "w") as handle:
            json.dump(data, handle)
        return path

    def test_file_values_and_defaults(self):
        settings = load(self.write({"port": 9000, "database_url": "postgres://db"}), environ={})
        self.assertEqual(settings["port"], 9000)
        self.assertEqual(settings["workers"], 4)
        self.assertIs(settings["debug"], False)

    def test_missing_required(self):
        with self.assertRaises(ConfigError):
            load(self.write({"port": 9000}), environ={})

    def test_unknown_setting(self):
        with self.assertRaises(ConfigError):
            load(self.write({"database_url": "x", "colour": "blue"}), environ={})

    def test_port_above_range(self):
        with self.assertRaises(ConfigError):
            load(self.write({"database_url": "x", "port": 70000}), environ={})


if __name__ == "__main__":
    unittest.main()
