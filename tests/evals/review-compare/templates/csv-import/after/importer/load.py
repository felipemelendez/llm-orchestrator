"""Import customer rows from CSV text."""
import csv
import io
from dataclasses import dataclass, field

from importer import fields

REQUIRED = ("email", "name", "plan")
OPTIONAL = ("age", "signup_date")


class HeaderError(ValueError):
    """The header row is missing required columns."""

    def __init__(self, missing):
        super().__init__("missing columns: " + ", ".join(missing))
        self.missing = missing


@dataclass
class RowError:
    line: int
    field: str
    message: str


@dataclass
class ImportResult:
    rows: list = field(default_factory=list)
    errors: list = field(default_factory=list)
    truncated: bool = False

    @property
    def rejected(self):
        return len({error.line for error in self.errors})


def check_header(header):
    names = [name.strip().lower() for name in header]
    missing = [name for name in REQUIRED if name not in names]
    if missing:
        raise HeaderError(missing)
    return names


def check_row(values, today):
    """Check every field of one row; return the cleaned row and its problems."""
    row, problems = {}, []
    checks = (
        ("email", fields.check_email),
        ("name", fields.check_name),
        ("plan", fields.check_plan),
        ("age", fields.check_age),
        ("signup_date", lambda value: fields.check_signup_date(value, today)),
    )
    for name, check in checks:
        try:
            row[name] = check(values.get(name) or "")
        except fields.FieldError as error:
            problems.append((name, str(error)))
    return row, problems


def import_customers(text, today, max_errors=None):
    reader = csv.reader(io.StringIO(text))
    try:
        header = check_header(next(reader))
    except StopIteration:
        raise HeaderError(list(REQUIRED)) from None
    result = ImportResult()
    seen = set()
    for line, record in enumerate(reader, start=2):
        if not any(cell.strip() for cell in record):
            continue
        values = dict(zip(header, record))
        row, problems = check_row(values, today)
        if not problems and row["email"] in seen:
            problems.append(("email", "duplicate email"))
        for name, message in problems:
            result.errors.append(RowError(line, name, message))
        if problems:
            if max_errors is not None and result.rejected >= max_errors:
                result.truncated = True
                break
            continue
        seen.add(row["email"])
        result.rows.append(row)
    return result
