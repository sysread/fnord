# Worktrees

Fnord supports git worktrees for isolating file changes during edit-mode conversations.
Each conversation can be bound to its own worktree so edits happen on a separate branch without touching the main working tree.

## How it works

In edit mode, the coordinator instructs the AI to create a worktree before making file changes.
The worktree is associated with the conversation and persisted in conversation metadata, so resuming the conversation (`--follow`) reuses the same worktree.

All file edits are scoped to the worktree directory.
The project root override mechanism ensures file tools resolve paths relative to the worktree, not the original working tree.

## The --worktree flag

```bash
fnord ask -q "refactor the config module" --edit --worktree /path/to/existing/worktree
```

`--worktree / -W PATH` overrides the project source root for the current run.
PATH must be an **existing directory** - this flag does not create worktrees.

If the conversation already has a worktree association (from a prior run), `--worktree` is rejected to prevent conflicting state.

## Conversation-bound worktrees

When the AI creates a worktree via the coordinator tool:

1. A new git worktree is created under `~/.fnord/projects/<project>/worktrees/<conversation-id>/`
2. The worktree metadata (path, branch, base branch) is persisted to the conversation
3. The project root override is set for the session
4. All subsequent file operations target the worktree

On resume (`--follow`), fnord:

- Detects the stored worktree association
- Verifies the worktree directory still exists
- Recreates it from the stored metadata if it was deleted
- Sets the project root override automatically

## CLI management

The `fnord worktrees` command provides direct management:

```bash
fnord worktrees list
fnord worktrees create --conversation <uuid>
fnord worktrees create --conversation <uuid> --branch feature-name
fnord worktrees delete --path /path/to/worktree
fnord worktrees merge --path /path/to/worktree
```

### list

Lists all worktrees with branch, merge status, and directory size.
Output is tab-separated.

### create

Creates a new conversation-scoped worktree.

- `--conversation / -c UUID` - conversation id (required)
- `--branch / -b NAME` - branch name (optional, auto-generated if omitted)

### delete

Removes a worktree by path.

- `--path / -P PATH` - absolute worktree path (required)

### merge

Merges a worktree branch into the base branch and removes the worktree.

- `--path / -P PATH` - absolute worktree path (required)

## Design notes

- `-W` is strictly an existing-directory override, never a creation hint
- One worktree per conversation - the coordinator enforces this
- Worktree recreation preserves the originally stored path
- The worktree tool is only available in edit mode on git repositories
