Conventions
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

# Guidelines
- Functions should do one thing well
  - prefer small, pure functions with clear behavior
  - use `|>` to chain transformations
  - prefer function heads over complex conditionals
  - prefer function heads over complex or nested `Enum` iterators (eg `each`, `reduce`)
  - prefer pattern matching over guards when possible
- Integration points
  - integration points are where different abstraction levels meet
    - it's integration levels all the way down; there is no single "lowest" level
    - everything workflow is an integration of smaller, more focused pieces
    - at the *very* least, entry points into a module are integration points
  - at significant integration points, use `with` to transition between lower-level concerns and higher-level logic
    - translate errors into domain-specific errors; what matters to the *caller* at this level of abstraction?
  - special cases should be handled at integration points, not buried in lower-level functions
  - integration points always get `@doc`s explaining how they fit into the bigger picture/larger feature
  - integration points should have basic positive and negative path tests for the expected/intended use cases
    - add tests as edge cases manifest
- Do not use in-line conditionals (eg `if ..., do: ..., else: ...`)
- Do not use `alias`s unless required
- `AI.Agent` is for implementations of that behaviour
- `AI.Tools` is for implementations of that behaviour
- `Services` is for genservers
- Prefer context modules that get called by integration/feature/behavior layers

# Operational note (important)
- This repository is *the runtime for the assistant*.
- Edits you make here change how the assistant behaves when operating inside this project.
- Make changes carefully:
  - Keep diffs small and covered by tests.
  - ALWAYS run `make check` locally with test HOME overrides whenever you believe changes are complete.
  - ALWAYS run `mix format` after edits!
