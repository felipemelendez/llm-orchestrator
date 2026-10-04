"""Where each user's files live."""
import os


def user_folder(root, user_id):
    """The folder holding one user's files."""
    if not user_id.isalnum():
        raise ValueError(f"bad user id: {user_id!r}")
    return os.path.join(root, "users", user_id, "files")
