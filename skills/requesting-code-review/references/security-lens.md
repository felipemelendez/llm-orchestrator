## Security lens

The change touches code that handles authentication, secrets, tokens or
payments. Also check:

- **Authentication and authorization:** missing checks, privilege escalation,
  broken access control.
- **Secrets and credentials:** secrets in code, logs, error messages or
  committed configuration.
- **Input handling:** SQL injection, command injection, path traversal,
  missing validation where untrusted data enters.
- **Cryptography:** weak algorithms, hard-coded keys, reused IVs or nonces,
  broken TLS settings.
- **Deserialization** of untrusted data without validation.
- **SSRF and CSRF:** server-side requests to addresses a user controls,
  missing CSRF protection on requests that change state.
- **Sensitive data in logs:** personal data, tokens or passwords written to
  log output.

A serious or catastrophic security finding names the concrete input or path
an attacker would use.
