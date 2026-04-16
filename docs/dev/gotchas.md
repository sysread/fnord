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
`Store.Project.Source.mode/1` (`lib/store/project/source.ex:38`) decides
per-project. Default branch resolution (`GitCli.default_branch/1`,
`lib/git_cli.ex:216`) does NOT fall back to the current branch. The chain
is `origin/HEAD` -> `main` -> `master` -> `nil`. When nil, the project
drops to `:fs` mode (working tree enumeration), not current-branch indexing.

## 4. Embedding dimension check on is_stale?

`Entry.is_stale?/1` (`lib/store/project/entry.ex:94`) reads the stored
embedding vector and checks `length == AI.Embeddings.dimensions()` (line 113).
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
