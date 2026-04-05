# Worktrees

Fnord supports git worktrees for isolating file changes during edit-mode conversations.
Each conversation can be bound to its own worktree so edits happen on a separate branch without touching the main working tree.

## How it works

In edit mode (`--edit`) on a git repository, fnord enforces worktree usage.
The coordinator is instructed to create a worktree before making any file changes, and file edit tools refuse to write without one.
All edits happen on an isolated branch — your working tree is never modified directly.
For non-git projects, edits are applied directly to the source files.

At the end of the session, you decide what to do with the changes: inspect the diff, merge into your current branch, or leave them in the worktree for later.
With `--yes`, the worktree changes are auto-merged and cleaned up at the end.

The worktree is associated with the conversation and persisted in conversation metadata, so resuming the conversation (`--follow`) reuses the same worktree.

File paths in UI output (tool notes, edit approval dialogs) are displayed relative to the source root, with the branch name shown in parentheses on edit approvals.

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

## Committing changes

The coordinator is nudged to commit its worktree changes at two points:

1. **Inline with validation**: after each code-modifying tool use, if uncommitted changes exist, a system message reminds the AI to commit via the `git_worktree_tool` commit action.
2. **Dedicated step**: a `:commit_worktree` step runs after task checking, before finalization. It loops up to 3 times if changes remain uncommitted.

The AI can commit normally or use `wip: true` for incomplete work, which prefixes the message with `WIP:`.

As a last resort, `maybe_auto_commit` in the ask command commits any remaining changes after the coordinator finishes.

## Post-session review

After the coordinator finishes in a fnord-managed worktree, the user is prompted to:

1. **Inspect changes**: view the diff between the worktree branch and its base
2. **Merge**: merge the branch into whatever is checked out in the actual project root
3. **Clean up**: delete the worktree directory and local branch

With `--yes`, the post-session review is skipped and changes are auto-merged with cleanup.

## Forking conversations with worktrees

When forking a conversation (`--fork / -F`) that has an associated worktree, the user is prompted:

- **Reuse existing worktree** (default): the forked conversation shares the original worktree
- **Create new worktree**: worktree metadata is stripped; the coordinator will create a fresh one
- **No worktree**: worktree metadata is stripped; no worktree is created

In non-interactive mode, the default (reuse) is applied.

## CLI management

The `fnord worktrees` command provides direct management:

```bash
fnord worktrees list
fnord worktrees create --conversation <uuid>
fnord worktrees create --conversation <uuid> --branch feature-name
fnord worktrees delete --conversation <uuid>
fnord worktrees merge --conversation <uuid>
```

### list

Lists fnord-managed worktrees in a formatted table with columns:
Conversation, Branch, Status, Dirty, Size, Path.

Only worktrees under the default fnord-managed path are shown (not user-created external worktrees).

### create

Creates a new conversation-scoped worktree.

- `--conversation / -c UUID` - conversation id (required)
- `--branch / -b NAME` - branch name (optional, auto-generated if omitted)

### delete

Removes a conversation's worktree. Checks for uncommitted and unmerged changes before deleting.

- `--conversation / -c UUID` - conversation id (required)

If the worktree has uncommitted changes, prompts for confirmation before force-deleting.
If the worktree branch has unmerged commits, warns and prompts before proceeding.
On deletion, worktree metadata is stripped from the conversation and a system message is injected so the AI knows the worktree is gone on follow-up.

### merge

Interactive review, merge, and cleanup of a conversation's worktree.

- `--conversation / -c UUID` - conversation id (required)

Walks through the same inspect/merge/cleanup flow as the post-session review.

## Conversation deletion

When deleting conversations (`fnord conversations --prune`), fnord checks each conversation for an associated worktree. If one exists on disk, the user is prompted about cleanup with status information (dirty/unmerged/clean).

## Design notes

- `-W` is strictly an existing-directory override, never a creation hint
- One worktree per conversation - the coordinator enforces this
- Worktree recreation preserves the originally stored path
- The worktree tool is only available in edit mode on git repositories
- The `git_worktree_tool` create action derives project and conversation from the active session; only branch is user-specified
- The `git_worktree_tool` commit action only works in fnord-managed worktrees
