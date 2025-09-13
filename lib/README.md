# Module Organization

This project follows Perl-style module organization where module names correspond directly to file paths.

## Structure

- `Foo` → `lib/foo.ex`
- `Foo.Bar` → `lib/foo/bar.ex`
- `Foo.Bar.Baz` → `lib/foo/bar/baz.ex`

## Examples

- `UI` module is in `lib/ui.ex`
- `UI.Queue` module is in `lib/ui/queue.ex`
- `AI.Tools.Shell` module is in `lib/ai/tools/shell.ex`
- `Services.Approvals.Shell` module is in `lib/services/approvals/shell.ex`

This organization makes it easy to locate modules and understand the codebase hierarchy at a glance.