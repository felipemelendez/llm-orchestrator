import unittest
from datetime import date

from importer.load import HeaderError, import_customers
from importer.report import format_report

TODAY = date(2026, 3, 1)
HEADER = "email,name,plan,age,signup_date\n"


class HeaderTest(unittest.TestCase):
    def test_missing_columns(self):
        with self.assertRaises(HeaderError) as caught:
            import_customers("email,age\n", TODAY)
        self.assertEqual(caught.exception.missing, ["name", "plan"])


class RowTest(unittest.TestCase):
    def test_valid_row(self):
        result = import_customers(HEADER + "ann@example.com,Ann,pro,34,2026-01-15\n", TODAY)
        self.assertEqual(result.errors, [])
        self.assertEqual(result.rows[0]["email"], "ann@example.com")
        self.assertEqual(result.rows[0]["age"], 34)
        self.assertEqual(result.rows[0]["signup_date"], date(2026, 1, 15))

    def test_optional_fields_may_be_empty(self):
        result = import_customers(HEADER + "bo@example.com,Bo,free,,\n", TODAY)
        self.assertEqual(result.rows[0]["age"], None)
        self.assertEqual(result.rows[0]["signup_date"], None)

    def test_bad_email_is_reported_with_line(self):
        text = HEADER + "ann@example.com,Ann,pro,,\nnot-an-email,Cy,team,,\n"
        result = import_customers(text, TODAY)
        self.assertEqual(len(result.rows), 1)
        self.assertEqual([(e.line, e.field) for e in result.errors], [(3, "email")])

    def test_unknown_plan(self):
        result = import_customers(HEADER + "dee@example.com,Dee,gold,,\n", TODAY)
        self.assertEqual(result.errors[0].field, "plan")


class ReportTest(unittest.TestCase):
    def test_report(self):
        text = HEADER + "ann@example.com,Ann,pro,,\nnot-an-email,Cy,team,,\n"
        report = format_report(import_customers(text, TODAY))
        self.assertEqual(report, "line 3: email: not a valid address\n1 imported, 1 rejected")


if __name__ == "__main__":
    unittest.main()
