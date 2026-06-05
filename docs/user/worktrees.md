# Worktrees

Fnord can use git worktrees to isolate file changes during edit-mode conversations.
On git repos, a conversation can carry its own worktree metadata and resume in that same checkout on later runs.

## How it works

In edit mode (`--edit`) on a git repository, fnord may create a fnord-managed worktree before the coordinator starts if the conversation does not already have one.
If the conversation is already bound to a worktree, fnord re-attaches to it before the session runs.

For non-git projects, edits are applied directly to the project files.

At the end of a session in a fnord-managed worktree, fnord can review, merge, keep, or discard the worktree depending on the session outcome and whether you are running interactively.
With `--yes`, fnord skips the interactive review and attempts the same merge-and-cleanup flow automatically.

The worktree association lives in conversation metadata, so `--follow` can restore the same path, branch, and base branch on later runs.

File paths in UI output are shown relative to the active project root. In a worktree session, that means paths are shown relative to the worktree.

## The --worktree flag

```bash
fnord ask -q "refactor the config module" --edit --worktree /path/to/existing/worktree
```

`--worktree / -W PATH` overrides the project root for the current run.
PATH must be an **existing directory**. This flag never creates a worktree.

If the conversation already has stored worktree metadata, fnord compares that metadata with the path you passed. Matching paths are reused. Conflicting paths are rejected.

## Conversation-bound worktrees

When fnord creates or resumes a conversation worktree:

1. A git worktree is created under `~/.fnord/projects/<project>/worktrees/<conversation-id>/` unless the conversation is already bound to a different path
2. The worktree metadata (path, branch, base branch) is stored with the conversation
3. The session root is redirected to that worktree
4. File tools operate against the worktree for the rest of the run

On resume (`--follow`), fnord:

- Detects stored worktree metadata
- Re-attaches if the directory still exists
- Recreates the worktree from the stored branch/base branch if it was deleted
- May adopt an existing fnord-managed worktree on disk if metadata was lost

Fnord also auto-discards empty speculative worktrees at session end when nothing changed and no extra commits were created.

## Gitignored files

Gitignored or excluded files written inside a worktree are tracked separately in conversation metadata.
During merge review, fnord copies those files back to the source repo before deleting the worktree so the changes are not lost just because git would ignore them.

## Initializing fresh worktrees

Fnord does not run project-specific setup commands when it creates a worktree.
If your repo is configured with a `post-checkout` hook, git will run that hook during `git worktree add`, including worktrees fnord creates.

One way to wire that up is to keep hooks in the repo and point git at them:

```sh
mkdir -p .githooks
cat > .githooks/post-checkout <<'EOF'
#!/bin/sh
# Runs after `git checkout` and `git worktree add`. Add any project-specific
# setup commands here (fetch dependencies, build initial artifacts, etc.).
EOF
chmod +x .githooks/post-checkout
git config core.hooksPath .githooks
```

The hook receives three arguments: previous HEAD, new HEAD, and a flag (`1` for branch checkout, `0` for file checkout). Use `$3 = 1` to limit setup to branch and worktree checkouts.

## Committing and review

Fnord can commit changes made in a fnord-managed worktree during or after the session.
If changes remain at the end, fnord can review the diff, merge the branch, and clean up the worktree.
If merge validation fails, fnord may loop back through the coordinator so the session can fix the reported issues before trying again.

If a fnord-managed worktree ends the session with no meaningful changes, fnord may discard it automatically instead of prompting for review.

## Forking conversations with worktrees

When forking a conversation (`--fork / -F`) that has worktree metadata, fnord can either keep using that worktree metadata or strip it so the new conversation starts without a bound worktree.
The exact prompt depends on whether the session is interactive.

## CLI management

The `fnord worktrees` command provides direct management:

```bash
fnord worktrees list
fnord worktrees create --conversation <uuid>
fnord worktrees create --conversation <uuid> --branch feature-name
fnord worktrees view --conversation <uuid>
fnord worktrees delete --conversation <uuid>
fnord worktrees merge --conversation <uuid>
```

### list

Lists fnord-managed worktrees for the current project, including branch and merge-related status.

### create

Creates a new conversation-scoped worktree.

- `--conversation / -c UUID` - conversation id (required)
- `--branch / -b NAME` - branch name (optional, auto-generated if omitted)

### view

Shows the diff of a conversation worktree from its fork point.

- `--conversation / -c UUID` - conversation id (required)

### delete

Removes a conversation's worktree.
Fnord checks the worktree state before deleting and updates the conversation metadata so follow-up runs no longer treat the conversation as bound to that worktree.

- `--conversation / -c UUID` - conversation id (required)

### merge

Reviews, merges, and optionally cleans up a conversation's worktree.

- `--conversation / -c UUID` - conversation id (required)

## Conversation deletion

When deleting conversations with `fnord conversations --prune`, fnord checks whether each conversation still has a worktree on disk and prompts about cleanup when needed.

## Design notes

- `-W` is strictly an existing-directory override, never a creation hint
- One worktree can be associated with a conversation at a time
- Worktree recreation preserves the stored path, branch, and base branch
- The `git_worktree_tool` create action derives project and conversation from the active session; only branch is user-specified
- The `git_worktree_tool` commit action only works in fnord-managed worktrees
