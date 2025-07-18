# Unit tests
- See `test/support/fnord_test_case.ex`.
- Default to `async: false`.
- Prefer `meck` over `mox` when possible. We are migrating away from `mox`.
- ONLY mock to avoid external dependencies, such as network calls. Look at Fnord.TestCase to see how to set up fixtures.

# Feature changes
- Always try to ensure that `README.md` is up-to-date with the latest changes.

# ALWAYS
- Run `mix test` to confirm that changes compile and do not break existing functionality.
- Run `mix format` to ensure code is formatted consistently.
- Run `ENV=dev mix dialyzer` to check for type errors.
