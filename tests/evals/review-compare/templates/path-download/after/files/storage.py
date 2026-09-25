"""Where user uploads are stored."""
from pathlib import Path


def save(storage, user_id, name, data):
    """Write an uploaded file into the user's folder and return its path."""
    folder = Path(storage) / user_id
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / Path(name).name
    path.write_bytes(data)
    return path
