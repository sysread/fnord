# Test Organization

This project follows Perl-style test organization that mirrors the `lib/` structure, with tests organized by the modules they test.

## Structure

- `Foo` tests → `test/foo_test.exs` (module: `FooTest`)
- `Foo.Bar` tests → `test/foo/bar_test.exs` (module: `Foo.BarTest`)
- Multiple tests for `Foo` → `test/foo/` directory with specific test files

## Examples

### Single test per module
- `UI` tests → `test/ui_test.exs` (module: `UITest`)
- `Settings` tests → `test/settings_test.exs` (module: `SettingsTest`)

### Multiple tests per module
When a module has multiple distinct aspects to test, create a subdirectory:

- `AI.Tools.Shell` tests:
  - `test/ai/tools/shell_test.exs` (module: `AI.Tools.ShellTest`)
  - `test/ai/tools/shell/validation_test.exs` (module: `AI.Tools.Shell.ValidationTest`)

- `Services.Approvals.Shell` tests:
  - `test/services/approvals/shell_test.exs` (module: `Services.Approvals.ShellTest`)
  - `test/services/approvals/shell/prefix_test.exs` (module: `Services.Approvals.Shell.PrefixTest`)

- `Cmd.Ask` tests:
  - `test/cmd/ask_test.exs` (module: `Cmd.AskTest`)
  - `test/cmd/ask/worktree_test.exs` (module: `Cmd.Ask.WorktreeTest`)

## Module Naming Pattern

**Critical**: Test module names must follow this exact pattern:
- File path: `test/path/to/module_test.exs` → Module: `Path.To.ModuleTest`
- File path: `test/path/to/module/aspect_test.exs` → Module: `Path.To.Module.AspectTest`

**Abbreviations and Acronyms**: Where letters represent words, they may be fully upcased:
- `test/ui_test.exs` → `defmodule UITest` (User Interface)
- `test/ai_test.exs` → `defmodule AITest` (Artificial Intelligence)
- `test/services/mcp_test.exs` → `defmodule Services.MCPTest` (Model Context Protocol)

Examples:
- `test/ui_test.exs` → `defmodule UITest`
- `test/services/approvals_test.exs` → `defmodule Services.ApprovalsTest`
- `test/services/approvals/shell_test.exs` → `defmodule Services.Approvals.ShellTest`
- `test/ai/tools_test.exs` → `defmodule AI.ToolsTest`

## Conventions

- All tests use `Fnord.TestCase` instead of `ExUnit.Case`
  - Before you set up complex setup scenarios, check if `Fnord.TestCase` already provides what you need.
  - If it doesn't, but it seems like something we might need again, consider adding it to `Fnord.TestCase`.
- Prefer `Mox` for mocking, but fall back to `meck` if the code to be mocked is not designed for dependency injection.
- Use `mix test --warnings-as-errors` and always ensure tests pass without warnings.
- Use `mix dialyzer` to check for type and contract issues.
- Use `mix coveralls` to ensure tests are adequately covering the codebase.
- Use `mix format` to ensure consistent code formatting.
- No aliases in test modules - use full module names
- Module names append `Test` to the final component (not `Shell.Test`, but `ShellTest`)
- Directory structure matches module hierarchy exactly
- Tests should not output directly to stdout/stderr (except *while* debugging)
- Tests should not output directly to stdout/stderr (except *while* debugging)

## Test Logging Defaults

All tests that `use Fnord.TestCase` now:

- Automatically run with a `@moduletag capture_log: true` tag.
- Have the Logger level set to `:warning` by default (so info/debug messages are suppressed but warnings/errors are still caught).

You can still adjust logging at runtime or on a per-module basis:

```elixir
defmodule MyFeatureTest do
  use Fnord.TestCase

  test "debug message is not printed by default" do
    assert Logger.level() == :warning
    Logger.debug("foo")
    # Debug is suppressed
  end

  test "temporarily raise to debug" do
    set_log_level(:debug)
    assert Logger.level() == :debug
  end
end
```

### Opting out of automatic capture

If you need console logs in your tests, disable the tag:

```elixir
defmodule NoisyTest do
  @moduletag capture_log: false
  use Fnord.TestCase

  test "prints to stderr" do
    assert capture_io(:stderr, fn -> Logger.error("bar") end) =~ "bar"
  end
end
```