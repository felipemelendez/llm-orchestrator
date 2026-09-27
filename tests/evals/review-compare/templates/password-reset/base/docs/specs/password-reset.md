# Password reset tokens

- `request(email)` issues a random token for an existing account and
  returns it for the caller to email. For an unknown address it returns
  None. Addresses are compared case-insensitively.
- Issuing a token revokes every earlier token for the same account.
- Only a hash of each token is stored.
- A token lasts one hour: from the moment one hour has passed, it is
  expired. A token works once; after a successful reset it is gone.
- The new password must have at least 12 characters. A rejected password
  does not use up the token.
- At most 3 requests per address per rolling hour, counted the same way for
  known and unknown addresses (so the limit does not reveal which addresses
  have accounts). A request exactly one hour old no longer counts. The 4th
  request in the window raises `RateLimited`.
