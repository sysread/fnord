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

## worktree_context_msg is the canonical state injection point

`AI.Agent.Coordinator.worktree_context_msg/1` (`lib/ai/agent/coordinator.ex:745`)
runs in every coordinator bootstrap and injects exactly one of two system messages:
"active worktree at `<path>` on `<branch>`" (with divergence note if base moved)
or "no worktree yet, create one before editing."

Any code that needs to communicate worktree state changes across sessions should
mutate conversation metadata and let the next bootstrap re-derive the message.
Do NOT append trailing system messages to `data.messages` to communicate state -
they break replay (see [gotchas.md](gotchas.md) item 20) and create redundancy
with the bootstrap injection.

`maybe_handle_forked_worktree` (`lib/cmd/ask.ex:581-583`) documents this
explicitly: it strips metadata only and relies on `worktree_context_msg` to
re-inject on the next bootstrap.

## git_info template ordering

`$$GIT_INFO$$` in coordinator prompts (`@common`, `@initial`,
`Coding.@prompt`) is substituted during bootstrap from `GitCli.git_info()`,
which reads `Settings.get_project_root_override() || File.cwd!()`.
If the worktree override is not set before `get_response/2` invokes the bootstrap,
the prompt embeds the source repo's branch, not the worktree branch.

`prepare_conversation_worktree/2` guarantees this ordering: it sets up the
worktree (and calls `Settings.set_project_root_override`) before `get_response/2`
is called.
`maybe_auto_create_worktree/4` enforces this for fresh edit sessions.

If you add a prompt template that references the current branch, git root, or any
repo state, ensure it is deferred until after worktree setup, or re-injected as a
fresh system message after worktree creation.

## External-merge resume context gap

When `Cmd.WorktreeLifecycle.clear_worktree_from_conversation/1` removes worktree
metadata after a merge or delete, the next bootstrap correctly injects "no
worktree, create one" - but the LLM cannot distinguish "you never had a worktree"
from "you had one that was merged/deleted out of band."

The right fix (not yet implemented as of April 2026): stash disposition in metadata
at cleanup time (`%{action: :merged | :deleted, branch, sha, at}`), have
`worktree_context_msg/1` inject a one-shot note on the next bootstrap, then clear
the disposition so it does not bleed into subsequent sessions.
This completes the "stash in metadata, inject on bootstrap" pattern that
`maybe_handle_forked_worktree` already uses (`lib/cmd/ask.ex:584-604`).
