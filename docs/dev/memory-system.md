# Memory System

Fnord has a three-scope memory model: global, project, and session. Global and
project memories persist as JSON files on disk. Session memories live inside
conversation metadata and are promoted to long-term storage by a background
indexer.

## Scopes

|Scope|Storage location|Lifetime|
|-------|-----------------|----------|
|`:global`|`~/.fnord/memory/`|Permanent, cross-project|
|`:project`|`~/.fnord/projects/<name>/memory/`|Permanent, per-project|
|`:session`|Conversation metadata `"memory"` key|Conversation lifetime; promoted by `MemoryIndexer`|

All three scopes implement the `Memory` behaviour (`lib/memory.ex:42`).

## Memory struct

`lib/memory.ex:2` defines the struct:

```text
scope, title, slug, content, topics, embeddings, inserted_at, updated_at, index_status
```

`index_status` values: `:new`, `:analyzed`, `:rejected`, `:incorporated`,
`:merged`, `:ignore`, or `nil` (line 28).

## File-backed storage

`Memory.FileStore` (`lib/memory/file_store.ex`) backs both global and project
scopes. One JSON file per memory, filename derived from `Memory.title_to_slug/1`
(`lib/memory.ex:662`).

### Collision handling

When two titles slug to the same filename, `FileStore` appends `-N` suffixes.
`allocate_unique_path_for_title/2` (`lib/memory/file_store.ex:236`) scans for
the next available index.

### Write locking

All writes go through a directory-level `.alloc.lock` file
(`lib/memory/file_store.ex:108`) acquired via `FileLock.with_lock`. Individual
file reads and writes also acquire per-file locks (lines 361, 372).

## Session-to-long-term promotion

`Services.MemoryIndexer` (`lib/services/memory_indexer.ex`) is a GenServer
that runs during `fnord ask` sessions. It independently scans conversations
for unprocessed session memories and promotes, rejects, or consolidates them
into long-term storage.

### Scan behavior

- Walks conversations oldest-first via `find_next_conversation/1` (line 187)
- Skips the currently active conversation (`current_conversation_id/0`, line 208)
- Skips conversations that previously failed to read (corrupt files)
- Filters for session memories with `index_status` of `nil` or `:new`
  (`find_unprocessed_memories/1`, line 444)

### Processing pipeline

For each conversation with unprocessed memories:

1. `build_indexer_payload/2` (line 455) -- enriches each session memory with
   up to 5 matching global and 5 matching project candidates via
   `recall_candidates/2` (line 476)
2. `invoke_indexer_agent/1` (line 489) -- runs the `AI.Agent.Memory.Indexer`
   LLM agent
3. `apply_actions_and_mark/3` (line 557) -- applies add/replace/delete actions
   inside `FileLock.with_lock` on the conversation file, then marks session
   memories as `:analyzed`

All payload titles are merged with the agent's `processed` list (line 561) so
that every memory given to the agent is marked processed, regardless of whether
the agent echoes the exact title back. Agents are unreliable at exact string
matching.

### Deep sleep

After the session memory queue empties, the indexer transitions to deep sleep
(once per process lifetime, gated by `Services.Once`). Deep sleep runs
`@deep_sleep_passes` (3) rounds of same-scope memory deduplication:

- `find_consolidation_pairs/1` (line 290) -- computes cosine similarity
  between all memory pairs within a scope
- Pairs above `@deep_sleep_min_score` (0.5) are selected greedily,
  highest-score first, with no memory appearing in more than one pair per pass
- `consolidate_pair/3` (line 366) -- invokes
  `AI.Agent.Memory.Deduplicator.run/2`; on merge, saves the synthesized
  memory first, then deletes both originals

## Staleness checks

`Memory.stale?/2` (`lib/memory.ex:447`) reads the stored embedding and checks
`stale_embedding?/2` (line 434): true when the embedding is `nil` or
`length(embeddings) != expected_dim`.

`Memory.lock_path/2` (`lib/memory.ex:465`) returns
`<memory_dir>/<slug>.embedding` for per-title locking during reindexing.

## Memory indexing during `fnord index`

`Cmd.Index.index_memories/0` (`lib/cmd/index.ex:528`) runs
`Memory.list_stale_long_term_memories/0` and reindexes each via the standard
`locked_task/3` pattern. See [indexing-flow.md](indexing-flow.md).

## Background backfill

`Services.MemoryIndexer.backfill_a_few_stale_memories/0`
(`lib/services/memory_indexer.ex:1085`) picks up to
`@memory_backfill_batch` (5) stale memories per scan cycle for lazy
re-embedding. Runs before each conversation scan pass.

## FileLock owner format

Lock owner files contain (`lib/file_lock.ex`):

```text
os_pid: <N>
beam_pid: #PID<...>
at: <iso8601>
```

The memory indexer's liveness check (`live_lock_owner?/1`,
`lib/services/memory_indexer.ex:919`) only trusts `Process.alive?/1` when
`os_pid` matches `System.pid()` (the current BEAM). Cross-BEAM PIDs fall
through to stale-age cleanup (`@orphan_lock_stale_ms` = 2 minutes).

## Orphan lock cleanup

`cleanup_orphan_memory_locks/0` (`lib/services/memory_indexer.ex:759`) runs on
startup and every 5 minutes. It scans global and project memory directories for
`*.json.lock` and `*.json.lock.released.*` directories where the target memory
file is missing, the lock age exceeds 2 minutes, and no live local owner PID
exists.
