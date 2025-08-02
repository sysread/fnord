# General
- This is an elixir escript app. Remember what that means for supervision, testing, and deployment.

# Code style
- Don't alias modules. Use the full module name instead.
- Avoid single line syntax (e.g. `if x, do: y` or `def foo(x), do: x + 1`).
- Always update the `@moduledoc` and `@doc` attributes when making changes to a module or function.
- Prefer `binary` over `String.t`, `list` over `List.t`, `map` over `Map.t`, etc. for `@type`s and `@spec`s (not because it's correct, but because it's more readable)
- Avoid using parens in type specs (e.g. `@spec foo(binary) :: binary` instead of `@spec foo(binary()) :: binary()`).

# Feature changes
- Ensure that `README.md` is up-to-date and accurate.

# Unit tests
- See `test/support/fnord_test_case.ex`.
- Default to `async: false`.
- Prefer `meck` over `mox` when possible. We are migrating away from `mox`.
- ONLY mock to avoid external dependencies, such as network calls. Look at Fnord.TestCase to see how to set up fixtures.

# NEVER
- Do not make changes unless explicitly requested by the user's prompt.
- Do not use `make` commands unless explicitly requested by the user's prompt.
- Do not use `elixirc` to test code changes. Use `mix compile` or `mix test` instead.
- Do not run `git clean` or `git reset --hard` in the codebase. This can lead to data loss.

# ALWAYS
- Run `mix test` to confirm that changes compile and do not break existing functionality.
- Run `mix format` to ensure code is formatted consistently.
- Run `ENV=dev mix dialyzer` to check for type errors.
- Use printf-debugging instead of `mix run` to troubleshoot.
- Shortcut: `make check` compiles the code, runs the tests, and checks for dialyzer errors.

# Learning
You must learn the project as you work in it, and persist your knowledge to improve your effectiveness in future sessions.
Begin EVERY session by reading your notes in `.claude/notes.md` to refresh your memory on the project context, patterns, and gotchas.
- Read `.claude/notes.md` at the start of each session to refresh context on project details and gotchas.
- Update `.claude/notes.md` whenever you discover new project facts, patterns, or gotchas that would be useful for future sessions.
- Update `.claude/notes.md` whenever you discover a conflicting fact that disagrees with the current notes. This helps maintain accurate project context.
- Regularly review and reorganize your notes to consolidate related information and remove duplicates.
- Avoid retaining ephemeral information that is not useful for future sessions, such as temporary debugging steps or a bug that has been fixed.
- Organize your notes by topic.
