# Command Reference

Reference for fnord CLI commands.
Commands with dedicated documentation link to it; everything else is covered here.

## ask

Ask the AI a question about the project.
This is the primary command - most fnord usage flows through it.

```bash
fnord ask -q "how does the auth middleware work?"
fnord ask -q "refactor the config module" --edit
fnord ask -q "continue from here" --follow <uuid>
```

See [Ask Options](ask-options.md) for the full list of flags and options.

## index

Index (or re-index) a project's files for semantic search and AI context.

```bash
fnord index
fnord index --dir /path/to/project
fnord index --reindex
fnord index --exclude "vendor/*" --exclude "*.min.js"
```

- `--dir / -d DIR` - project root directory (required on first index or after moving)
- `--exclude / -x PATTERN` - glob pattern to exclude (repeatable, persisted to config)
- `--reindex / -r` - force full rebuild of the index
- `--quiet / -Q` - suppress progress bar, log file names instead
- `--yes / -y` - assume yes to all prompts

On first run, fnord asks for the project root directory (or uses `--dir`).
Subsequent runs detect new, changed, and deleted files automatically.

`--reindex` deletes all existing entries before rebuilding.
`--exclude` patterns are stored in project config and apply to all future runs.

After indexing, fnord offers to prime the knowledge base if no research notes exist yet.

## search

Perform a semantic search across indexed files.

```bash
fnord search -q "authentication middleware"
fnord search -q "error handling" --limit 20 --detail
```

- `--query / -q QUERY` - search query (required)
- `--limit / -l N` - max results (default: 10)
- `--detail` - include AI-generated file summaries in output

Output is tab-separated: similarity score and file path.

## files

List all indexed files in the current project.

```bash
fnord files
fnord files --relpath
```

- `--relpath / -r` - print paths relative to cwd instead of stored paths

## projects

List all known projects.

```bash
fnord projects
```

No options.
Prints one project name per line.

## conversations

List, search, or prune conversations.

```bash
fnord conversations
fnord conversations -q "worktree setup" --limit 10
fnord conversations --prune 30
fnord conversations --prune <uuid>
```

- `--query / -q QUERY` - semantic search across conversations
- `--limit / -l N` - max search results (default: 5)
- `--prune / -P VALUE` - prune by age (integer = days) or delete a specific conversation (uuid)

Default output (no options) lists all conversations as JSON with `id`, `timestamp`, `question`, `file`, and `length`.

Pruning by age requires interactive confirmation and cannot be undone.

## replay

Replay a saved conversation to stdout.

```bash
fnord replay -c <uuid>
```

- `--conversation / -c UUID` - conversation id to replay (required)

## summary

Show the AI-generated summary and code outline for an indexed file.

```bash
fnord summary -f lib/settings.ex
```

- `--file / -f FILE` - file path to summarize (required)

## torch

Permanently delete a project from the store.

```bash
fnord torch
```

Irreversible.
Deletes all indexed data, conversations, and notes for the project.

## config

See [Configuration Reference](config.md) for `config set`, `config list`, validation rule management, MCP subcommands, and related subcommands.

Approval-specific commands:

```bash
fnord config approvals
fnord config approvals --global
fnord config approve --kind shell --global "mix"
fnord config approve --kind shell_full "git status"
```

See [Approval Patterns](approval-patterns.md) for the full guide.

## frobs

See [Frobs Developer Guide](frobs-guide.md).

## skills

See [Skills](skills.md).

## memory

List or search across memory scopes (session, project, global).

```bash
fnord memory
fnord memory -q "validation rules"
fnord memory --global
```

## notes

List facts about the project inferred from prior research conversations.

```bash
fnord notes
fnord notes --reset
```

## prime

Prime fnord's research notes with basic information about the project by running an initial indexing pass.

```bash
fnord prime
```

## worktrees

See [Worktrees](worktrees.md).
