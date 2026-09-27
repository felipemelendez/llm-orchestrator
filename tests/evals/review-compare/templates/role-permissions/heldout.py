"""Held-out check for role-permissions: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys

sys.path.insert(0, ".")
from docsvc.models import User  # noqa: E402
from docsvc.service import DocumentService, PermissionDenied  # noqa: E402

ANN = User("ann", "acme")
BOB = User("bob", "acme")
ADMIN = User("carol", "acme", frozenset({"admin"}))
OTHER_ADMIN = User("oz", "globex", frozenset({"admin"}))
VIEWER = User("dan", "acme", frozenset({"viewer"}))
OUTSIDE_VIEWER = User("eve", "globex", frozenset({"viewer"}))
SUSPENDED_ANN = User("ann", "acme", suspended=True)
OUTSIDER = User("olga", "globex")


def denied(action, *args):
    try:
        action(*args)
    except PermissionDenied:
        return True
    return False


def check():
    s = DocumentService()
    doc = s.create(ANN, "Plan")
    assert denied(s.get, OTHER_ADMIN, doc.id), "an admin of another org has no rights"
    assert denied(s.delete, OTHER_ADMIN, doc.id), "an admin of another org cannot delete"
    assert denied(s.get, SUSPENDED_ANN, doc.id), "a suspended owner cannot read"
    assert denied(s.update, SUSPENDED_ANN, doc.id, "x"), "a suspended owner cannot edit"

    s.share(ANN, doc.id, BOB, "view")
    assert denied(s.update, BOB, doc.id, "x"), "a view share cannot edit"
    assert denied(s.share, BOB, doc.id, VIEWER, "view"), "a shared user cannot re-share"
    assert denied(s.share, ANN, doc.id, OUTSIDER, "view"), "cannot share outside the org"
    assert denied(s.share, ANN, doc.id, BOB, "owner"), "only view and edit are share levels"
    assert denied(s.share, ANN, doc.id, BOB, ""), "an empty level is not a share level"

    s.share(ANN, doc.id, BOB, "edit")
    assert denied(s.delete, BOB, doc.id), "a shared editor cannot delete"

    visible = s.create(ANN, "Handbook", org_visible=True)
    assert s.get(VIEWER, visible.id)
    assert denied(s.get, OUTSIDE_VIEWER, visible.id), "org_visible is for the same org only"
    assert denied(s.update, VIEWER, visible.id, "x"), "a viewer cannot edit an org-visible document"

    s.archive(ANN, doc.id)
    assert s.get(BOB, doc.id), "an archived document stays readable"
    assert denied(s.update, BOB, doc.id, "x"), "a shared editor cannot edit an archived document"
    assert denied(s.update, ANN, doc.id, "x"), "the owner cannot edit an archived document"
    assert denied(s.share, ANN, doc.id, VIEWER, "view"), "the owner cannot share an archived document"
    s.update(ADMIN, doc.id, "admin")
    s.share(ADMIN, doc.id, VIEWER, "view")
    s.delete(ANN, doc.id)

    assert denied(s.create, SUSPENDED_ANN, "x"), "a suspended user cannot create"
    assert [d.id for d in s.list_readable(OUTSIDE_VIEWER)] == []


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
