# Research classifier — curated examples

These rows are parsed by `tests/test-research-classifier.sh` as its case source — the table below is the input, not a copy of it. They are ground truth: if a heuristic change in [`SKILL.md`](./SKILL.md) moves any of these to the wrong outcome, or an Expected cell here stops matching the heuristics, the test fails — surface it before merge. Keep the row format (`| "Input" | \`NEEDED\`/\`SKIP\` | why |`); the test also fails if the table stops parsing.

| Input                                                       | Expected | Why                                              |
|-------------------------------------------------------------|----------|--------------------------------------------------|
| "Add a function that returns the current ISO timestamp"     | `SKIP`   | Pure logic. No library surface.                  |
| "Fix the typo in README.md"                                 | `SKIP`   | Mechanical edit.                                 |
| "Rename `users` to `accounts` throughout users.ts"          | `SKIP`   | Refactor; type system catches errors.            |
| "Add a test for users.ts:42"                                | `SKIP`   | Established pattern.                              |
| "Add OAuth login with Auth0"                                | `NEEDED` | Library + security verb.                         |
| "Migrate the test suite from Mocha to Vitest"               | `NEEDED` | Library transition; version-shifted APIs.        |
| "Set up Next.js 14 middleware for tenant routing"           | `NEEDED` | Version + framework + architectural verb.        |
| "Add a Prisma migration for the user_policy table"          | `NEEDED` | Library; migrations are version-sensitive.       |
| "Implement JWT token refresh"                               | `NEEDED` | Security verb.                                   |
| "Reduce the cyclomatic complexity of users.ts:checkAccess"  | `SKIP`   | Pure refactor; no API surface.                   |
| "Add a debounce util in src/lib/"                           | `SKIP`   | Pure logic.                                      |
| "Wire Stripe Checkout with the v15 SDK"                     | `NEEDED` | Library + version + payment (security-sensitive).|
