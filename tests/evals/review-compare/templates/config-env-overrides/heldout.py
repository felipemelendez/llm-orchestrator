"""Held-out check for config-env-overrides: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, ".")
from config.loader import ConfigError, load  # noqa: E402

TMP = tempfile.mkdtemp()


def write(data):
    path = os.path.join(TMP, "app.json")
    with open(path, "w") as handle:
        json.dump(data, handle)
    return path


def raises(data, environ=None):
    try:
        load(write(data), environ=environ or {})
    except ConfigError:
        return True
    return False


def check():
    ok = {"database_url": "postgres://db"}
    assert load(write(ok), environ={"APP_PORT": "9100"})["port"] == 9100, "APP_PORT overrides the file"
    assert load(write(dict(ok, port=9000)), environ={"APP_PORT": "9100"})["port"] == 9100, "env wins"
    assert load(write(ok), environ={"APP_DEBUG": "0"})["debug"] is False, "0 is false"
    assert load(write(ok), environ={"APP_DEBUG": "Yes"})["debug"] is True, "Yes is true"
    assert raises(ok, {"APP_DEBUG": "maybe"}), "a bad boolean is an error"
    assert load(write(dict(ok, port=1)), environ={})["port"] == 1, "the minimum is inclusive"
    assert load(write(dict(ok, port=65535)), environ={})["port"] == 65535, "the maximum is inclusive"
    assert raises(ok, {"APP_PORT": "0"}), "an environment value is range-checked"
    assert raises(ok, {"APP_WORKERS": "500"}), "an environment value is range-checked"
    assert raises(dict(ok, workers=True)), "a boolean is not an int"
    assert raises({}), "database_url is required"
    assert raises(ok, {"APP_PORT": "eighty"}), "an unparsable override is an error"
    assert load(write(dict(ok, timeout=5)), environ={})["timeout"] == 5.0, "an int is accepted for a float"
    path = os.path.join(TMP, "list.json")
    with open(path, "w") as handle:
        json.dump([1, 2], handle)
    try:
        load(path, environ={})
    except ConfigError:
        pass
    else:
        raise AssertionError("a JSON array is not a config object")


if __name__ == "__main__":
    try:
        check()
    except Exception as e:
        print(f"held-out check failed: {e!r}")
        sys.exit(1)
    print("held-out check passed")
