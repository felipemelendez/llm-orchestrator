"""Export a user's files into an export folder."""
import os
import shutil
import subprocess
import sys

STRIP_PREFIX = "draft-"
RENAMES = {".jpeg": ".jpg", ".htm": ".html", ".yml": ".yaml"}
DEFAULT_LEVEL = 6

GZIP_SCRIPT = """
import gzip, os, shutil, sys
path, level = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as src, gzip.open(path + ".gz", "wb", compresslevel=level) as dst:
    shutil.copyfileobj(src, dst)
os.remove(path)
"""


def export_name(name):
    """The name a file gets in the export: prefix removed, extension renamed."""
    name = name.removeprefix(STRIP_PREFIX)
    stem, ext = os.path.splitext(name)
    return stem + RENAMES.get(ext.lower(), ext)


def target_path(export_dir, name):
    """Where a file the user calls `name` is written inside export_dir."""
    return os.path.join(export_dir, export_name(os.path.basename(name)))


def compress_file(path, level=DEFAULT_LEVEL):
    """Gzip `path` in a separate Python process; return the path of the .gz file."""
    subprocess.run([sys.executable, "-c", GZIP_SCRIPT, path, str(level)], check=True)
    return path + ".gz"


def export_files(source_dir, export_dir, names=None, compress=False, level=None):
    """Copy the user's files into export_dir and return the exported names, sorted."""
    if not os.path.isdir(source_dir):
        raise FileNotFoundError(source_dir)
    names = names or {}
    level = DEFAULT_LEVEL if level is None else level
    os.makedirs(export_dir, exist_ok=True)
    exported = []
    for folder, dirs, files in os.walk(source_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for filename in files:
            source = os.path.join(folder, filename)
            if filename.startswith(".") or os.path.islink(source):
                continue
            relative = os.path.relpath(source, source_dir).replace(os.sep, "/")
            target = target_path(export_dir, names.get(relative, filename))
            shutil.copyfile(source, target)
            if compress:
                target = compress_file(target, level)
            exported.append(os.path.basename(target))
    return sorted(exported)
