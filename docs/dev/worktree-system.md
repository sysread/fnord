# Worktree System

Edit-mode conversations use git worktrees to isolate file changes from the
source repo. Worktrees are auto-created before the coordinator starts, stored
alongside the project, and merged or discarded at session end.

## Location

```text
~/.fnord/projects/<name>/worktrees/<conversation-id>/
```

`GitCli.Worktree.default_root/1` (`lib/git_cli/worktree.ex:32`) returns the
parent directory. `GitCli.Worktree.conversation_path/2` (line 40) appends the
conversation ID.

## Creation

`GitCli.Worktree.create/3` (`lib/git_cli/worktree.ex:64`) creates the
worktree, branching from the default base branch. The branch name defaults to
`fnord-<conversation-id>`.

Auto-creation happens in `Cmd.Ask.maybe_auto_create_worktree/4`
(`lib/cmd/ask.ex:892`). Conditions:

- `--edit` is set
- `GitCli.is_git_repo?()` is true
- No worktree already exists for this conversation

The worktree metadata (path, branch, base_branch) is stored in conversation
metadata and used to re-attach on `--follow`.

## File edit redirection

All file-tool operations target the worktree, not the source repo.
`Settings.set_project_root_override(path)` redirects the project root for the
session. Every tool that reads or writes files goes through the project root,
so the override is transparent to tool implementations.

See [gotchas.md](gotchas.md) item 11 for how worktree context is injected as
a system message.

## Auto-commit

`Cmd.Ask.maybe_auto_commit/3` (`lib/cmd/ask.ex:1108`) runs after the
coordinator finishes. It calls `GitCli.Worktree.commit_all/2` with a generic
"auto-commit" message. Only fires when:

- Edit mode is on
- The path is a fnord-managed worktree (`GitCli.Worktree.fnord_managed?/2`)
- There are uncommitted changes (returns `:nothing_to_commit` cleanly when
  there aren't)

## Merge review

`GitCli.Worktree.Review` handles the merge flow. Two modes:

### Interactive mode

`GitCli.Worktree.Review.interactive_review/3` shows a diff, prompts the user
to merge or squash. The user can inspect changes before accepting.

### Auto mode

`GitCli.Worktree.Review.auto_merge/3` merges without prompting, triggered by
`--yes`.

### Validation hooks

Validation can run checks (e.g. `make check`) on the worktree before merge.
On failure, `Cmd.Ask.maybe_worktree_review/5` (`lib/cmd/ask.ex:1253`) loops
back to the coordinator to fix the issues, up to `@max_merge_attempts` (3)
attempts. Each retry re-invokes the coordinator with the validation output as
context.

### Merge results

|Result|Action|
|--------|--------|
|`{:cleaned_up, sha, mode}`|Worktree metadata cleared from conversation|
|`{:validation_failed, phase, summary}`|Retry loop|
|`{:merge_failed, reason}`|Show worktree hints, leave unmerged|
|`:ok` (user declined)|Show worktree hints, leave unmerged|

## Cleanup

`Cmd.WorktreeLifecycle.clear_worktree_from_conversation/1`
(`lib/cmd/worktree_lifecycle.ex`) strips worktree metadata from the
conversation JSON after a successful merge. `GitCli.Worktree.delete/2` removes
the worktree from disk and prunes the branch.

## Empty worktree discard

`Cmd.Ask.maybe_discard_empty_worktree/2` (`lib/cmd/ask.ex:1195`) auto-discards
worktrees at session end when:

- The worktree has no uncommitted changes
- No commits exist beyond the base (zero-length diff from fork point)
- No gitignored writes are tracked

This catches speculatively created worktrees that the coordinator never edited.

## Gitignored file handling

Worktree edits to gitignored or excluded files are tracked in conversation
metadata under the `gitignored_writes` key. These files exist in the worktree
but would not survive a git merge.

During merge review, `Cmd.Ask.copy_ignored_writes/3` (`lib/cmd/ask.ex:1172`)
copies tracked gitignored files from the worktree back to the source repo
before the worktree is deleted. This runs eagerly before the merge flow: if
the merge fails and the worktree survives, the copies in the source repo are
harmless (they're gitignored there too).

## Re-attach on --follow

When continuing a conversation with `--follow`, worktree metadata from the
stored conversation is used to re-attach. If the worktree directory still
exists, `resolve_conversation_worktree/4` (`lib/cmd/ask.ex:978`) sets the
project root override. If the directory was deleted (e.g. manual cleanup),
`recreate_conversation_worktree/3` (line 1001) recreates it from the stored
branch and base branch.

Orphaned worktrees (directory exists but metadata was lost, e.g. from SIGTERM
before conversation save) are adopted automatically (line 942).
