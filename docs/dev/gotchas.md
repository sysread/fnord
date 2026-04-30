# Gotchas

Non-obvious invariants and footguns in the fnord codebase. Each item is
something that either caused a real bug, would cause one if violated, or
requires understanding that isn't obvious from the code alone.

## 1. Lazy project resolution

The project isn't resolved until after CLI parsing. Commands declare
`requires_project?() = true`, but resolution happens in `set_globals/1`
(`lib/fnord.ex:182`). `ResolveProject.resolve/1` runs inside `set_globals/1`
only when the user didn't pass `--project` explicitly (line 212). Tools must
handle nil projects gracefully: several tool modules check
`AI.Tools.get_project/0` and return structured errors rather than crashing.

## 2. FileLock freshness recheck inside the lock

`locked_task/3` (`lib/cmd/index.ex:468`) calls `still_stale?.()` **inside**
`FileLock.with_lock`, not before it. A parallel worker can finish the item
between an outside staleness check and lock acquisition. The recheck closes
this TOCTOU race. Removing or hoisting the recheck re-opens the window for
redundant LLM calls.

## 3. Git projects index the default branch, not the working tree

A user on a feature branch still sees `main` indexed.
`Store.Project.Source.mode/1` (`lib/store/project/source.ex:36`) decides
per-project. Default branch resolution (`GitCli.default_branch/1`,
`lib/git_cli.ex:216`) does NOT fall back to the current branch. The chain
is `origin/HEAD` -> `main` -> `master` -> `nil`. When nil, the project
drops to `:fs` mode (working tree enumeration), not current-branch indexing.

## 4. Embedding dimension check on is_stale?

`Entry.is_stale?/1` (`lib/store/project/entry.ex:94`) reads the stored
embedding vector and checks `length == AI.Embeddings.dimensions()` (`lib/ai/embeddings.ex:18`).
The cross-format hash upgrade (`hash_is_current?/1`, line 150) can mark a
file fresh when its content hasn't changed, but the entry is still stale if
the embedding was produced by a different model with a different vector
dimension. These two staleness axes are independent.

## 5. AI.Splitter assumes valid UTF-8

`String.split_at/2` uses the grapheme walker. Non-UTF-8 bytes crash it.
`Indexer.guard_text/1` (`lib/indexer.ex:82`) is the enforcement point:
`String.valid?(content)` returns `{:error, :binary_file}` before content
reaches the splitter. If new code paths bypass `guard_text`, binary-tracked
files will crash the indexer.

## 6. UI log tag casing

Bracketed tags in `UI.info`/`UI.warn`/`UI.debug` calls are lowercase by
convention. Examples: `[embeddings]`, `[notes-server]`, `[memory_indexer]`.
Tags appear in log output and tee transcripts. Mixing casing breaks grep-based
log analysis.

## 7. `make check` is the canonical quality gate

Runs compile with `--warnings-as-errors`, tests, dialyzer, and markdownlint
(`lib/`, `test/`, `docs/`). Run as a single command:

```sh
make check
```

Do not chain with `&&`; the Makefile target handles sequencing and the "All
checks passed" confirmation.

## 8. Pool does not cap pending requests

Back-pressure in the embeddings pipeline happens in `embed.exs`'s worker pool,
not in the GenServer queue. If the pool workers are all busy, new requests
queue indefinitely in the GenServer mailbox. Timeout or port death fails the
individual caller; there is no built-in retry or circuit breaker.

## 9. Two-phase service startup

Core services (`Services.start_all/0`, `lib/services.ex:2`) start before CLI
parsing: Globals, UI.Queue, Registry, Once, Notes, BackupFile, TempFile,
FileCache, TaskSupervisor. Config-dependent services
(`Services.start_config_dependent_services/1`, line 43) start after
`set_globals/1`: NamePool, Approvals, Approvals.Gate. MCP is started lazily
on first tool access. This split avoids circular dependencies between services
that need config and the CLI parser that sets it.

## 10. Conversations persist incrementally

Messages are appended during the session. Replay assumes the last message is
the assistant's final response. Appending system messages mid-conversation
(e.g. during worktree cleanup or validation-fix loops) can break replay
expectations if the final message ends up being a system message rather than
an assistant response.

## 11. Worktree context is a system message, not agent state

The worktree context (path, branch, base_branch) is re-computed and injected
as a fresh system message on every `--follow`. It is not serialized as part of
the agent's internal state. Stale worktree metadata from a prior session
can't silently persist: the system message is rebuilt from the conversation's
stored metadata each time. See
[worktree-system.md](worktree-system.md) for the full worktree lifecycle.

## 12. --workers only controls the embeddings pool

The `--workers N` flag to `fnord index` overrides the embedding pool concurrency
(`AI.Embeddings.Pool.ensure_started/1`). It does NOT affect:

- HTTP connection pool sizes (hardcoded in `lib/fnord.ex:13-16`)
- `async_stream` concurrency (defaults to `System.schedulers_online()`)
- LLM request parallelism (coordinator is single-threaded)

Oversubscribing `--workers` without matching HTTP pool sizes just queues
embedding requests behind a connection bottleneck.

## 13. tools_used slices from initial_message_count, not last user message

`AI.Completion.tools_used/1` (`lib/ai/completion.ex:179`) drops `state.initial_message_count`
messages (snapshotted in `new/1`) and counts tool calls in the remainder.
This is stable against mid-loop user-message injection from
`maybe_apply_interrupts/1`, which inserts user messages between tool rounds
within a single `get/1` call.

Known hole: compaction.
When `handle_response` replaces `state.messages` with a compacted list on
`:context_length_exceeded`, `initial_message_count` becomes a stale offset
relative to the new list.
`tools_used` will either undercount (offset still in range, skips real tool calls)
or overshoot (`Enum.drop` with an offset larger than the list returns `[]`).

Trigger to watch for: "(no file changes during this session)" on a session whose
log contains a `[compaction]` line before the post-ask check.
If it surfaces, escalate to option A: track tool names explicitly in a
`:round_tool_calls` field on the completion struct, updated in `handle_tool_calls/1`.
That decouples tool tracking from message structure entirely.

## 14. `Owl.LiveScreen.await_render/0` is not a per-item call

`Owl.LiveScreen` renders on a 60ms timer.
`await_render/0` blocks the caller until the NEXT tick of that timer.
Calling it per item in a tight loop (e.g. inside an `async_stream` reducer)
serializes the entire loop on Owl's clock: up to 60ms per item, ~60s for 1000
items, regardless of how fast the underlying work is.

`Owl.ProgressBar.inc/1` is sufficient on its own inside the loop; Owl picks up
the counter on its next render pass.
Reserve `await_render/0` for end-of-phase flush calls, not inside per-item reducers.

The pathology existed in `UI.progress_bar_update/1` before commit `616421e0`.

## 15. meck: expect without new leaks a mock forever

`:meck.expect(Mod, :func, fn -> ... end)` on a module that has NOT been
`:meck.new`'d creates an implicit mock that never unloads.
Every subsequent test that calls `Mod.func` sees the mock rather than the real
implementation, regardless of seed or isolation.
Detection: intermittent suite failures on specific seeds where a function returns
unexpected values only when the full suite runs.

Always `safe_meck_new(Mod, [:passthrough])` before any `:meck.expect` call, and
register cleanup before the `new` call:

```elixir
on_exit(fn -> safe_meck_unload(Mod) end)
:ok = safe_meck_new(Mod, [:passthrough])
:meck.expect(Mod, :func, fn -> ... end)
```

Registering `on_exit` AFTER test assertions risks leaking the mock if an assertion
fails mid-body before registration runs.
`FnordTestCase` (`test/support/fnord_test_case.ex`) force-clears `UI` and
`GitCli` in the global setup to absorb leaks from any test that skips this pattern.

Audit command: `grep -rn ':meck.expect(' test/` and verify each module has a
corresponding `safe_meck_new` in setup.

## 16. on_exit + linked Agent.stop race

`on_exit` runs in a process separate from the test pid.
A linked helper started with `Agent.start_link` or `GenServer.start_link` inside
the test body may already be exiting via link propagation when `on_exit` fires.
`Agent.stop(pid, :normal, :infinity)` raises if the process exits with `:shutdown`
instead of `:normal`, turning a clean test into a CI failure.

Use `Process.exit(pid, :shutdown)` for cleanup-only stops in `on_exit` - it is
async, fire-and-forget, and never raises.
See `test/ai/completion_test.exs` tool-round cap test for the pattern.

The race is timing-sensitive: a new `:persistent_term` write (like the
`GitCli.default_branch` memoize) triggers a global GC on first write per key,
which can shift scheduling enough to flip a flaky test from green to red on CI.

## 17. Source ls-tree uses two persistent_term cache shapes

`Store.Project.Source` caches ls-tree output in two independent shapes:

- `cached_ls_tree/2` - `[{sha, rel_path}]` list, used by `list/1` for enumeration.
- `cached_path_map/2` - `%{rel_path => sha}` map, used by `hash/2` and `exists?/2` for O(1) lookup.

Both are keyed by `{__MODULE__, :ls_tree | :path_map, root, branch}` in
`:persistent_term` and frozen for the BEAM's lifetime.
The path map is derived from the list on first access.

Before this split, `hash/2` and `exists?/2` called `Enum.find`/`Enum.any?` over
the list, making `index_status/2`'s `async_stream` scan O(N^2) in tree size.
A 10k-file repo was doing tens of millions of string compares per scan.

New hot-path lookups over ls-tree should use `cached_path_map`; do not add a
third list scan.

## 18. GitCli.default_branch is memoized per BEAM

`GitCli.default_branch/1` (`lib/git_cli.ex:216`) caches its result in
`:persistent_term` keyed on the repo root.
The underlying resolver (`resolve_default_branch/1`) forks 2-4 git subprocesses
on first call but is O(1) on every subsequent call within the same BEAM instance.

`Source.mode/1`, `Source.hash/2`, and `Source.exists?/2` all call `default_branch`
inside `async_stream` fan-outs.
Without the cache, a 1k-file scan triggered thousands of fork/exec round trips.

The cache is never invalidated within a BEAM run.
This is safe because a single fnord invocation is short-lived and the branch tip
won't advance during a scan.
If you add a new per-file hot-path check that determines git-ness, call
`Source.mode/1` freely; do NOT add a new uncached git subprocess in its place.

## 19. Reviewer preflight anchors on project.source_root, not CWD

`AI.Agent.Review.Decomposer.resolve_target/1` anchors all `git`/`gh` operations
on `Store.get_project().source_root`, not `File.cwd!()` or
`GitCli.Worktree.project_root()`.

`fnord ask -p <project>` does NOT set a project root override (see
`Cmd.Ask.set_worktree/1`, which bails when `opts[:project]` is set).
Without the override, `GitCli.Worktree.project_root()` resolves to the process
CWD's git root - which is fnord's own repo when running `./fnord`.
`gh pr view 5995` would run against fnord rather than the target project.

`Store.get_project().source_root` already honors
`Settings.get_project_root_override()` (via `Store.Project.new/2`),
so it covers both `-p` and `-W` cases.
Any new tool that delegates to `git` or `gh` should anchor on
`Store.get_project().source_root`.

## 20. replay breaks on trailing non-assistant messages

`AI.Completion.Output.replay_conversation_as_output/1`
(`lib/ai/completion/output.ex:194`) treats the literal last message as the final
assistant response.
Any system or user message appended after the last assistant reply causes replay
to output that message via the formatter and print the actual assistant reply in
italics (wrong order, wrong style).

The root cause is `Cmd.WorktreeLifecycle.clear_worktree_from_conversation/1`
(removed in `ba17f8ca`) previously appending a worktree-deleted note after the
assistant's final reply.
The worktree system no longer does this, but the fragility remains.

Fix option A (defensive): find the last `role: "assistant"` message with non-nil
string content rather than using `Enum.split(-1)`.
Fix option B (structural): stash post-session notes in conversation metadata and
inject via bootstrap rather than appending to `messages`.

## 21. AI.Completion has a tool-round cap

`AI.Completion.get/1` caps tool-call rounds at 75 per invocation.
When the counter hits the cap, `specs` and `toolbox` are set to nil and a system
message tells the model the cap was hit and to produce a final response.
The next API call has no tool surface, forcing `{:ok, :msg, ...}`.

Override via env var: `FNORD_TOOL_ROUND_CAP=N`.
If a complex task legitimately needs more rounds, raise the cap via the env var
rather than removing the guard.

Symptom of a legitimate cap hit: the session produces an abrupt summary response
mid-task with no tool calls.
Check `state.tool_round_count` at the failure point before assuming a bug.
