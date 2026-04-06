# Validation Rules

Validation rules let you define shell commands that run automatically when the AI modifies files matching specified patterns.
Use them to enforce linting, type checking, formatting, or test suites whenever code-modifying tool usage changes matching files.

## Adding a rule

```bash
fnord config validation add "mix format --check-formatted" --path-glob "lib/**/*.ex" --path-glob "test/**/*.exs"
fnord config validation add "npm run lint" --path-glob "src/**/*.ts"
fnord config validation add "make check"
```

- `COMMAND` - shell command to run from the project root (required)
- `--path-glob PATTERN` - file pattern that triggers this rule (repeatable)

If no `--path-glob` is specified, the rule triggers on any file change.

Commands run from the project root directory.

## Listing rules

```bash
fnord config validation list
```

Output is JSON with each rule's index, command, and path globs.
Rule indices start at 1.

## Removing rules

```bash
fnord config validation remove 1
fnord config validation clear
```

`remove` deletes a single rule by its displayed index.
`clear` removes all validation rules for the project.

## How rules are matched

When the AI modifies a file, fnord checks each rule's path globs against the changed file's path.
If any glob matches (or if the rule has no globs), the rule's command executes.

Path globs use shell-style pattern matching and support quoted segments with spaces.

## Example workflow

Set up a rule to run the full check suite whenever Elixir source files change:

```bash
fnord config validation add "make check" --path-glob "lib/**/*.ex" --path-glob "test/**/*.exs"
```

Now when code-modifying tool usage changes any `.ex` or `.exs` file, `make check` runs automatically and the AI sees the output.
