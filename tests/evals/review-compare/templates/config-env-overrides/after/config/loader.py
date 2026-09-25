"""Load service settings from a JSON file, with environment overrides."""
import json
import os
from dataclasses import dataclass

ENV_PREFIX = "APP_"
TRUE_WORDS = {"1", "true", "yes", "on"}
FALSE_WORDS = {"0", "false", "no", "off"}


class ConfigError(ValueError):
    """A setting is missing, unknown, of the wrong type, or out of range."""


@dataclass(frozen=True)
class Setting:
    name: str
    type: type
    default: object = None
    minimum: object = None
    maximum: object = None
    required: bool = False


SCHEMA = (
    Setting("port", int, 8080, minimum=1, maximum=65535),
    Setting("workers", int, 4, minimum=1, maximum=64),
    Setting("debug", bool, False),
    Setting("timeout", float, 30.0, minimum=0.1),
    Setting("database_url", str, required=True),
)


def read_file(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ConfigError("the config file must hold a JSON object")
    return data


def parse_env(setting, raw):
    """Turn the text of an environment variable into the setting's type."""
    if setting.type is bool:
        word = raw.strip().lower()
        if word in TRUE_WORDS:
            return True
        if word in FALSE_WORDS:
            return False
        raise ConfigError(f"{setting.name}: {raw!r} is not a boolean")
    try:
        return setting.type(raw.strip())
    except ValueError:
        raise ConfigError(f"{setting.name}: {raw!r} is not a valid {setting.type.__name__}") from None


def check_type(setting, value):
    """Check a value read from the file; an integer is accepted where a float is expected."""
    if setting.type is float and isinstance(value, int) and not isinstance(value, bool):
        return float(value)
    if setting.type is int and isinstance(value, bool):
        raise ConfigError(f"{setting.name}: expected int, got a boolean")
    if not isinstance(value, setting.type):
        raise ConfigError(f"{setting.name}: expected {setting.type.__name__}")
    return value


def check_range(setting, value):
    if setting.minimum is not None and value < setting.minimum:
        raise ConfigError(f"{setting.name}: {value} is below the minimum {setting.minimum}")
    if setting.maximum is not None and value > setting.maximum:
        raise ConfigError(f"{setting.name}: {value} is above the maximum {setting.maximum}")


def load(path, environ=None):
    """Read `path`, apply APP_* overrides from `environ`, and return the checked settings."""
    environ = os.environ if environ is None else environ
    data = read_file(path)
    unknown = sorted(set(data) - {setting.name for setting in SCHEMA})
    if unknown:
        raise ConfigError(f"unknown settings: {', '.join(unknown)}")
    settings = {}
    for setting in SCHEMA:
        env_name = ENV_PREFIX + setting.name.upper()
        if env_name in environ:
            value = parse_env(setting, environ[env_name])
        elif setting.name in data:
            value = check_type(setting, data[setting.name])
        elif setting.required:
            raise ConfigError(f"{setting.name} is required")
        else:
            value = setting.default
        check_range(setting, value)
        settings[setting.name] = value
    return settings
