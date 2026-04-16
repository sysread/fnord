# Ask Coordinator

`fnord ask` is the primary interactive command. It starts background services,
sets up a conversation, runs a multi-phase LLM coordinator with tool access,
and handles post-response workflows including worktree commit and merge review.

## Entry point

`Cmd.Ask.run/3` (`lib/cmd/ask.ex:141`). The startup sequence, in order:

1. Start transcript tee (`maybe_start_tee/1`, line 339)
2. Print edit-mode warnings if `--edit`
3. Start embedding pool: `AI.Embeddings.Pool.ensure_started()` (line 183)
4. Run embedding migration check (line 184)
5. Start background indexers: file, commit, conversation, memory (lines 191-194)
6. Validate options (`validate/1`, line 404)
7. Set auto-approval policy (`set_auto_policy/1`, line 602)
8. Cache original source root (`cache_original_source_root/0`, line 530)
9. Set worktree override if `--worktree` (line 544)
10. Fork conversation if `--fork` (`maybe_fork_conversation/1`, line 618)
11. Start `Services.Conversation` GenServer (line 206)
12. Start `Services.Task` (line 207)
13. Initialize memory: `Memory.init/0` (line 211)
14. Prepare conversation worktree (`prepare_conversation_worktree/2`, line 872)
15. Get response from coordinator (`get_response/2`, line 734)
16. Save conversation (`save_conversation/1`, line 1062)
17. Auto-commit, merge review, print result

## Conversation server

`Services.Conversation` (`lib/services/conversation.ex`) is a GenServer that
holds in-memory conversation state: messages, metadata, and the agent instance.
Key operations:

- `start_link/1` -- accepts an optional conversation ID for `--follow`
- `get_response/2` -- dispatches to the coordinator agent
- `append_msg/2` -- adds a message without saving
- `save/1` -- writes the conversation to disk as a timestamped JSON file under
  `<project_store>/conversations/`

## Coordinator agent

`AI.Agent.Coordinator` runs the multi-phase LLM conversation. Phases control
which tools are available. Tool calls are dispatched through the `AI.Tools`
registry. See [tool-system.md](tool-system.md).

## Worktree injection

Before the first coordinator turn, a system message describing the worktree
state (path, branch, base_branch) is injected so the LLM makes edits in the
worktree rather than the source repo. This message is re-computed and injected
fresh on every `--follow`, so stale metadata can't persist across sessions.
See [worktree-system.md](worktree-system.md) and
[gotchas.md](gotchas.md) item 11.

## Auto-commit and merge review

After the coordinator finishes:

1. `maybe_auto_commit/3` (`lib/cmd/ask.ex:1105`) -- commits any uncommitted
   changes in the worktree with a generic message. Only fires when edit mode
   is on and a fnord-managed worktree exists.
2. `maybe_discard_empty_worktree/2` (line 1195) -- discards worktrees with no
   commits beyond base and no uncommitted changes. Speculatively created
   worktrees that went unused are cleaned up here.
3. `worktree_has_changes_to_merge?/2` (line 1131) -- source-of-truth check
   combining uncommitted changes, branch-ahead-of-base, and tracked
   gitignored writes.
4. `maybe_worktree_review/5` (line 1253) -- interactive or auto merge review.
   Interactive mode shows a diff and prompts. Auto mode (with `--yes`) merges
   without prompting. Validation failures loop back to the coordinator up to
   `@max_merge_attempts` (3) times.

## Conversation save

`Services.Conversation.save/1` writes the conversation to disk. The output
file lives under `<project_store>/conversations/`. Messages are appended
during the session. See [gotchas.md](gotchas.md) item 10 for replay
assumptions.

## Tee / transcript

`--tee <file>` pipes ANSI-stripped output to a file via `UI.Tee` GenServer.
`--TEE` is the force-overwrite variant that truncates without prompting
(line 89). Guard logic in `guard_existing_tee_file/2` (line 371) handles
interactive vs non-interactive overwrite confirmation.

## --follow / --fork

`--follow <UUID>` continues an existing conversation. The conversation server
loads the stored messages and metadata, including worktree state for re-attach.

`--fork <UUID>` branches a conversation: `Store.Project.Conversation.fork/1`
creates a copy with a new ID. `maybe_handle_forked_worktree/1` (line 645)
prompts about worktree disposition:

- **Reuse existing worktree** -- keep the source worktree as-is
- **Duplicate worktree** -- independent branch from the same start point
- **Create new worktree** -- strip metadata, coordinator creates fresh
- **No worktree** -- strip metadata, no worktree

## Memory initialization

`Memory.init/0` (`lib/memory.ex:89`) calls init on all three scope
implementations (Global, Project, Session), then calls `ensure_me/0`
(line 765) to guarantee a "Me" memory exists in global scope. This identity
memory seeds the LLM's self-model across sessions.

## Background indexers

Four background indexers run during ask sessions:

- `Services.BackgroundIndexer` -- file entries
- `Services.CommitIndexer` -- git commits (only if git repo)
- `Services.ConversationIndexer` -- conversation embeddings
- `Services.MemoryIndexer` -- session memory promotion + stale embedding
  backfill

All except `MemoryIndexer` are stopped in the `after` block (line 316).
The memory indexer is left running until BEAM exit to complete its deep sleep
pass.
