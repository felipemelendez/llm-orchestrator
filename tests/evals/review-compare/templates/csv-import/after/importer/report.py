"""Human-readable summary of an import."""


def format_report(result):
    lines = [f"line {error.line}: {error.field}: {error.message}" for error in result.errors]
    summary = f"{len(result.rows)} imported, {result.rejected} rejected"
    if result.truncated:
        summary += " (stopped early: too many errors)"
    lines.append(summary)
    return "\n".join(lines)
