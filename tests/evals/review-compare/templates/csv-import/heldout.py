"""Held-out check for csv-import: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys
from datetime import date

sys.path.insert(0, ".")
from importer.load import HeaderError, import_customers  # noqa: E402
from importer.report import format_report  # noqa: E402

TODAY = date(2026, 3, 1)
HEADER = "email,name,plan,age,signup_date\n"


def run(body, **kwargs):
    return import_customers(HEADER + body, TODAY, **kwargs)


def errors(result):
    return [(e.line, e.field) for e in result.errors]


def check():
    r = import_customers(" Email , NAME,Plan\nann@example.com,Ann,pro\n", TODAY)
    assert len(r.rows) == 1, "header names matched case-insensitively"
    try:
        import_customers("", TODAY)
    except HeaderError:
        pass
    else:
        raise AssertionError("empty file accepted")

    r = run("a@x.io,A,free,13,\nb@x.io,B,free,120,\nc@x.io,C,free,12,\nd@x.io,D,free,121,\n")
    assert errors(r) == [(4, "age"), (5, "age")], "age bounds are 13 to 120 inclusive"
    r = run("a@x.io,A,free,abc,\n")
    assert errors(r) == [(2, "age")], "a non-numeric age is an error"

    r = run("Ann@Example.com,Ann,pro,,\nann@example.COM,Ann Two,pro,,\n")
    assert [row["email"] for row in r.rows] == ["ann@example.com"], "email stored lowercased"
    assert errors(r) == [(3, "email")], "duplicate email compared case-insensitively"
    r = run("x@x.io,X,free,,\ny@x.io,Y,free,,\nx@x.io,X again,free,,\n")
    assert errors(r) == [(4, "email")], "duplicate email on the later row"

    r = run("a@x.io,A,PRO,,\n")
    assert r.rows and r.rows[0]["plan"] == "pro", "plan in any case, stored lowercased"

    r = run("a@x.io,A,free,,2026-03-01\nb@x.io,B,free,,2026-03-02\n")
    assert errors(r) == [(3, "signup_date")], "today allowed, tomorrow rejected"

    r = run("\n  ,  , ,,\na@x.io,A,free,,\nbad,B,free,,\n")
    assert r.errors and errors(r) == [(5, "email")], "blank rows skipped but counted for numbering"

    r = run("bad,,gold,,\ngood@x.io,G,free,,\n")
    assert r.rejected == 1 and len(r.errors) == 3, "rejected counts rows, not errors"
    assert format_report(r).endswith("1 imported, 1 rejected"), "report counts rows"

    body = "".join(f"bad{i},N,free,,\n" for i in range(5)) + "ok@x.io,O,free,,\n"
    r = run(body, max_errors=2)
    assert r.truncated and r.rejected == 2, "stop once max_errors rows are rejected"
    assert format_report(r).endswith("(stopped early: too many errors)")
    r = run(body)
    assert not r.truncated and r.rejected == 5 and len(r.rows) == 1


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
