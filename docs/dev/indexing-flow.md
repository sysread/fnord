# Indexing Flow

`fnord index` scans a project's source, classifies entries by freshness,
deletes stale entries, and re-indexes across four content phases. Concurrent
`fnord index` invocations on the same project cooperate via per-item file locks.

## Entry point

`Cmd.Index.run/3` (`lib/cmd/index.ex:79`) constructs the index state, calls
`perform_task/1` (line 139), optionally primes notes on clean exit, then
translates results to exit codes.

### Startup sequence

1. Pool startup: `AI.Embeddings.Pool.ensure_started(pool_opts)` (line 151)
   with optional `--workers N` override
2. Migration check: `AI.Embeddings.Migration.maybe_migrate(:index)` (line 152)
3. Print project/source/exclude info
4. Run `index_project/1` (line 377)

### Source line header

The source mode is printed at startup via `describe_source/1` (line 423):

- Git mode: `Source: git default branch (main)`
- FS mode: `Source: working tree`

See [storage-layout.md](storage-layout.md) for details on source mode selection.

## Index project pipeline

`index_project/1` (`lib/cmd/index.ex:377`) runs:

1. `maybe_reindex/1` -- on `--reindex`, deletes all stored entries and commit
   index, then continues with a full scan
2. `scan_project/1` -> `Store.Project.index_status/1`
   (`lib/store/project.ex:397`) -- classifies entries into `new`, `stale`,
   `deleted`
3. `delete_entries/1` -- removes stored entries for deleted source files
4. `index_entries/1` -- re-indexes new + stale files

### Four phases

After file indexing, three more phases run in order:

|Phase|Function|Returns|
|-------|----------|---------|
|Files|`index_entries/1` (line 618)|`:ok` or `{:partial, ok, err}`|
|Commits|`index_commits/1` (line 789)|`:ok` or `{:partial, ok, err}`|
|Conversations|`index_conversations/1` (line 638)|`:ok` or `{:partial, ok, err}`|
|Memories|`index_memories/0` (line 528)|`:ok` or `{:partial, ok, err}`|

Results are aggregated by `aggregate_phase_results/1` (line 439).

## Per-item worker pattern

Every indexable item runs through `locked_task/3` (`lib/cmd/index.ex:468`):

```text
FileLock.with_lock(lock_key, fn ->
  if still_stale?.(), do: do_work.(), else: :skipped
end)
```

Contract:

- **Lock contention** (`{:error, :lock_failed}`): returns `:skipped`
- **Callback crash** (`{:callback_error, e}`): returns `:error`
- **Freshness recheck** (`still_stale?.()`) runs **inside** the lock.
  This closes the TOCTOU race: a parallel worker can finish the item
  between an outside staleness check and lock acquisition. See
  [gotchas.md](gotchas.md) item 2.

## Reduce phase

`reduce_phase/2` (`lib/cmd/index.ex:501`) tracks four distinct outcomes:

|Outcome|Meaning|
|---------|---------|
|`:ok`|Worker completed successfully|
|`:skipped`|Already fresh on disk (another worker finished it, or lock contention)|
|`:binary`|File failed UTF-8 guard; permanently non-indexable|
|`:error`|Real failure; counts toward partial-failure exit code|

Phase summary format: `"Indexed N file(s); skipped M already-fresh; K binary (not indexable); L failed"`

`:binary` is distinct from `:skipped`. Binary files are not "already fresh";
they are permanently non-indexable under the current pipeline. No metadata is
written for binaries, so they reappear as "new" on every scan.

## Exit codes

`maybe_halt_on_failure/1` (`lib/cmd/index.ex:102`):

|Code|Meaning|
|------|---------|
|0|All phases succeeded|
|1|Hard error|
|2|Partial failure (`{:partial, ok, err}`)|

## Binary file handling

`Indexer.guard_text/1` (`lib/indexer.ex:82`) checks `String.valid?(content)`.
Non-UTF-8 content returns `{:error, :binary_file}` before reaching the
splitter. The splitter (`AI.Splitter`) uses `String.split_at/2` which walks
graphemes and would crash on invalid UTF-8.

Since no stored entry is written for binary files, they reappear as "new" on
every scan. Users who track binary artifacts should add them to the project's
`exclude` list.

## Cooperative parallel runs

Two `fnord index` processes on the same project cooperate via the per-item
`FileLock`. `FileLock.acquire_lock/1` (`lib/file_lock.ex:74`) calls
`File.mkdir_p` on the parent directory so workers can lock paths whose target
directory doesn't exist yet.

A worker that loses the lock race returns `:skipped`, which rolls into the
same exit-code bucket as `:ok` -- the item is up-to-date on disk regardless
of which worker did the work.

## --workers flag

`--workers N` overrides the embedding pool concurrency. Clamped at
`System.schedulers_online() * 4` by `clamp_workers/1`
(`lib/cmd/index.ex:407`). Only affects the embeddings pool; see
[gotchas.md](gotchas.md) item 12.

## Memory indexing phase

The memory phase (`index_memories/0`, line 528) calls
`Memory.list_stale_long_term_memories/0` and re-indexes each via
`Memory.reindex_memory/2`. Uses the same `locked_task/3` pattern with
`Memory.lock_path/2` as the lock key. See
[memory-system.md](memory-system.md) for memory scope details.
