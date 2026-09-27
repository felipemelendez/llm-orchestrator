# Typed settings with environment overrides

- Settings come from a JSON file that must hold an object. A key the schema
  does not name is an error (`ConfigError`), so typos are caught.
- Each setting has a type (`int`, `float`, `bool` or `str`), a default, and
  optionally a minimum and maximum (both inclusive). `database_url` has no
  default and is required.
- An environment variable `APP_<NAME>` (the setting name in upper case)
  overrides the file. Its text is parsed to the setting's type; booleans
  accept `1/true/yes/on` and `0/false/no/off`, in any case. Text that does not
  parse is a `ConfigError`, never a silent default.
- In the file, an integer is accepted for a float setting. A JSON boolean is
  never accepted for an int setting.
- Every value, from the file, the environment or the default, is checked
  against the minimum and maximum.
