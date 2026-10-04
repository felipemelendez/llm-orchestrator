import unittest

from names.text import BadTag, is_reserved, normalize_name, parse_tags, valid_username


class UsernameTest(unittest.TestCase):
    def test_valid(self):
        for name in ("alice", "Bob_99", "x_y"):
            self.assertTrue(valid_username(name), name)

    def test_invalid(self):
        for name in ("al", "1abc", "_bob", "bob smith", "a" * 21, "bob-1", ""):
            self.assertFalse(valid_username(name), name)

    def test_reserved(self):
        for name in ("admin", "Root", "SYSTEM", "staff7"):
            self.assertTrue(is_reserved(name), name)
        for name in ("alice", "administrator", "rooted"):
            self.assertFalse(is_reserved(name), name)


class NormalizeTest(unittest.TestCase):
    def test_case_and_spacing(self):
        self.assertEqual(normalize_name("  Ann   Lee "), normalize_name("ann lee"))
        self.assertNotEqual(normalize_name("Ann Lee"), normalize_name("Anne Lee"))


class TagsTest(unittest.TestCase):
    def test_simple_field(self):
        self.assertEqual(parse_tags("Python, rust,python"), ["python", "rust"])

    def test_quoted_tag(self):
        self.assertEqual(parse_tags('"salt, pepper",jam'), ["salt, pepper", "jam"])

    def test_hash_and_spaces(self):
        self.assertEqual(parse_tags("#news, machine   learning"), ["news", "machine learning"])

    def test_empty(self):
        self.assertEqual(parse_tags(""), [])
        self.assertEqual(parse_tags("a,,b"), ["a", "b"])

    def test_bad_tags(self):
        for field in ("c++", "a" * 31, "news#"):
            with self.assertRaises(BadTag):
                parse_tags(field)


if __name__ == "__main__":
    unittest.main()
