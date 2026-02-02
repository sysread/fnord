# Conventions
- Tests
  - Use `Fnord.TestCase` and helpers (`mock_project`, `tmpdir`).
  - Prefer `async: false` for most tests due to global state and GenServers.
  - **Always** use `Settings.get_user_home()` for paths in production and tests; do not use `System.user_home!()`.
- Compile-time vs runtime
  - This is an escript app, so there is no built-in elixir app config.
  - Module attributes evaluate at compile time.
  - Use `defp` functions for values that must reflect runtime or test settings.
- Persistence and concurrency
  - Use atomic writes (temp file + rename). See `Settings.write_atomic!`.
  - Use `FileLock` for concurrent access; prefer per-file locks.
  - Separate concerns into distinct files.
- Build / quality
  - Run `make check` before commit: `mix format`, `mix test`, `mix dialyzer`.
  - Treat compilation warnings as errors. Public functions should have `@spec`.
  - This is not a library; there is no need to worry about any external API stability.

# Operational note (important)
- This repository is *the runtime for the assistant*.
- Edits you make here change how the assistant behaves when operating inside this project.
- Make changes carefully:
  - Keep diffs small and covered by tests.
  - ALWAYS run `make check` locally with test HOME overrides whenever you believe changes are complete.
  - ALWAYS run `mix format` after edits!
