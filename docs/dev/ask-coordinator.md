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

## Prompt phases: fresh vs follow-up

`AI.Agent.Coordinator.initial_msg/1` has three clauses matched top-down:

1. `%{followup?: true}` - injects `@followup_system` (= `@common` + a short "continuation mode" note).
   Fires for both read-only and edit `-f`/`-F` sessions, regardless of `edit?`.
2. `%{edit?: false}` - injects `@initial` (heavy prescriptive planning prompt).
   Fresh read-only sessions only.
3. `%{edit?: true}` - delegates to `Coding.base_prompt_msg/1`
   (STORIES/EPICS/POST-CODING-CHECKLIST prompt).
   Fresh edit sessions only.

The heavy planning prompts are intentionally NOT re-injected on follow-up.
Prior to this split, every `-f`/`-F` bootstrap re-injected the full prompts,
priming the LLM to re-plan the entire task from scratch on each follow-up.

When adding a new fresh-only prompt injection, add a matching follow-up variant
or gate it on `followup?: false` so the slim `-f`/`-F` path stays slim.

## Coordinator test mode

User prompts starting with `testing:` (case-insensitive) bypass the normal
`bootstrap/1 -> perform_step/1` pipeline entirely.
`AI.Agent.Coordinator.Test.is_testing?/1` detects the prefix;
`consider/1` dispatches to `AI.Agent.Coordinator.Test.get_response/1`.

`Test.get_response/1` builds its own short `messages` list directly:
the test-mode system prompt, `FNORD.md`/`FNORD.local.md` via
`Store.Project.project_prompt/1`, the external-configs catalog via
`ExternalConfigs.Catalog.build_messages/0`, and the user question.
It does NOT use `Services.Conversation`, so anything that relies on
`Services.Globals.get_env(:fnord, :current_conversation)` - worktree tool
metadata writes, memory indexer, `ExternalConfigs.Injector` - will quietly no-op.

When adding new bootstrap-time injections that should reach the LLM, mirror them
into `Test.get_response/1` or they will be invisible to `testing:` prompts.

## Coding step reactivity

The `:coding` step is gated by `coding_work_pending?/1` and is a complete no-op
when the predicate is false.
`coding_work_pending?(state)` returns true when any of:

- `state.editing_tools_used` is set (code-modifying tools fired this round)
- `AI.Agent.Coordinator.Tasks.pending_lists(state) != []` (pending task-list items)
- `worktree_needs_commit?()` (fnord-managed worktree with uncommitted changes)

A fresh edit-mode session where the LLM only reasoned (no file edits, no task
lists, nothing to commit) skips the coding phase entirely - no banner, no prompt
injection, no completion call.

The "you enabled `-e` but didn't use your tools" nudge lives in `:finalize` as
`unused_edit_tools_nudge_msg/1` in `coordinator.ex`.
It fires when `edit?: true` AND `not coding_work_pending?(state)`, so it only
reaches the LLM at the end of a session that genuinely skipped coding.

If you add a new "coding is happening" signal, extend `coding_work_pending?/1`
so both the step gate and the nudge react correctly.

## Sub-agent message isolation

Sub-agents invoked inside a coordinator session - `TaskPlanner`, `TaskImplementor`,
`TaskValidator` (via `AI.Agent.Code.Common.new/5`), and `Researcher`
(via `AI.Agent.Researcher.get_response/1`) - build their own `messages` lists
and pass them directly to `AI.Agent.get_completion/2`.
They do NOT read from `Services.Conversation`.

Context appended to the coordinator's conversation via
`Services.Conversation.append_msg/2` after a sub-agent's message list was
constructed will NOT be visible to that sub-agent.
`Services.Globals.get_env(:fnord, :current_conversation)` is still the
coordinator's pid even when read from inside a sub-agent call; do not use it as
a proxy for "the conversation this LLM call will see."

Thread context explicitly into sub-agent constructors.
See `ExternalConfigs.Catalog.build_messages/0` and its three call sites
(`Common.new/5`, `Researcher.get_response/1`,
`Coordinator.Test.get_response/1`) for the pattern.

## Prompt vocabulary: "finalize"

System messages that reference the end-of-response event should use "finalize" /
"after you finalize your response."
This anchors the LLM in the same vocabulary the coordinator state machine uses
for the `:finalize` step.
"Session end" and "end of session" are ambiguous: the LLM may interpret them as
something already triggered or wait for an external signal before acting.

Example: "the merge into `<base_branch>` happens automatically at session end,
*after* you finalize your response" - the "after you finalize" clause is what
tells the LLM the merge is post-response.
