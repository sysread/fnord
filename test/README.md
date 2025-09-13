# Test Organization

This project follows Perl-style test organization that mirrors the `lib/` structure, with tests organized by the modules they test.

## Structure

- `Foo` tests → `test/foo_test.exs` (module: `Foo.Test`)
- `Foo.Bar` tests → `test/foo/bar_test.exs` (module: `Foo.Bar.Test`)
- Multiple tests for `Foo` → `test/foo/` directory with specific test files

## Examples

### Single test per module
- `UI` tests → `test/ui_test.exs` (module: `UI.Test`)
- `Settings` tests → `test/settings_test.exs` (module: `Settings.Test`)

### Multiple tests per module
When a module has multiple distinct aspects to test, create a subdirectory:

- `AI.Tools.Shell` tests:
  - `test/ai/tools/shell/test.exs` (module: `AI.Tools.Shell.Test`)
  - `test/ai/tools/shell/validation_test.exs` (module: `AI.Tools.Shell.Validation.Test`)

- `Services.Approvals.Shell` tests:
  - `test/services/approvals/shell/test.exs` (module: `Services.Approvals.Shell.Test`)
  - `test/services/approvals/shell/prefix_test.exs` (module: `Services.Approvals.Shell.Prefix.Test`)

- `Cmd.Ask` tests:
  - `test/cmd/ask/test.exs` (module: `Cmd.Ask.Test`)
  - `test/cmd/ask/worktree_test.exs` (module: `Cmd.Ask.Worktree.Test`)

## Conventions

- All tests use `Fnord.TestCase` instead of `ExUnit.Case`
- No aliases in test modules - use full module names
- Test module names eliminate type stutters (e.g., `Shell.Test` not `Shell.ShellTest`)
- Directory structure matches module hierarchy exactly