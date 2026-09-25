# Verifying webhook signatures

- Each request carries `X-Signature: t=<unix seconds>,v1=<hex>`, possibly
  with several `v1=` parts. Every part must be `key=value`; anything else
  makes the header malformed.
- The signed payload is `"<t>."` followed by the raw body bytes. A signature
  is the hex HMAC-SHA256 of that payload with a secret. Compare signatures
  with `hmac.compare_digest`.
- `Receiver(secrets, tolerance=300)` needs at least one secret (`ValueError`
  otherwise). During secret rotation it holds several; a request is valid when
  any `v1` signature matches any secret.
- `verify(headers, body, now)` raises `InvalidSignature` when the header is
  missing or malformed, has no `t` or no `v1`, when `t` is more than
  `tolerance` seconds before or after `now` (exactly `tolerance` is
  accepted), or when no signature matches.
- A verified event whose `id` was already accepted within the tolerance
  window raises `ReplayedEvent`. Otherwise the event is recorded and returned.
