import unittest

from net.errors import PermanentError, TransientError, classify


class ClassifyTest(unittest.TestCase):
    def test_classes(self):
        self.assertIsNone(classify(200))
        self.assertIs(classify(503), TransientError)
        self.assertIs(classify(429), TransientError)
        self.assertIs(classify(404), PermanentError)


if __name__ == "__main__":
    unittest.main()
