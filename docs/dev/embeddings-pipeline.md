# Embeddings pipeline

Embeddings are computed locally via `all-MiniLM-L12-v2` (384-dim, mean pooling) running under a bundled Elixir script (`embed.exs`) spawned as an Erlang Port. No network calls. An `AI.Embeddings.Pool` GenServer is the single point of contact for the rest of the app.

## Why local

Prior to this architecture, fnord used OpenAI's `text-embedding-3-large` (3072-dim) for every embed call. That added per-index API cost, latency, and hard-coupled the semantic layer to an external dependency. MiniLM-L12-v2 runs in-process via Bumblebee/EXLA, embeds in single-digit milliseconds per call, and is cheap enough that we can re-embed liberally.

## Components

### `AI.Embeddings` (`lib/ai/embeddings.ex`)

Thin public module. `AI.Embeddings.get/1` is the callable surface; it trims input, rejects empty strings, and delegates to `Pool.embed/1`. `AI.Embeddings.dimensions/0` returns `384` (compile-time constant). `AI.Embeddings.model_name/0` returns `"all-MiniLM-L12-v2"`.

### `AI.Embeddings.Pool` (`lib/ai/embeddings/pool.ex`)

GenServer that supervises one long-lived `embed.exs` Erlang Port.

- `ensure_started/1` — idempotent entry point called by every command that needs embeddings.
- `embed/1` — blocks on a `GenServer.call` with a 5-minute timeout. Enqueues a JSONL request, correlates the response by id.
- `shutdown/0` — graceful stop; suppresses the inevitable port-death messages by setting a `shutting_down?` flag first.

Error tuples callers must handle:

- `{:error, :pool_not_running}` — forgot to call `ensure_started/1`.
- `{:error, :port_not_connected}` — call arrived during a respawn window.
- `{:error, :port_died}` — port died while in-flight; caller can retry.
- `{:error, :timeout}` — 5-minute deadline.
- `{:error, :shutting_down}` — pool is terminating.
- `{:error, binary}` — structured error from `embed.exs` itself.

### `AI.Embeddings.Script` (`lib/ai/embeddings/script.ex`)

Bundles the `embed.exs` script + `embed.sh` wrapper as module attributes (`@embed_script`, `@embed_wrapper`). `ensure_scripts!/0` writes them to `~/.fnord/embed.exs` and `~/.fnord/embed.sh` on first use. On every subsequent spawn, byte-for-byte equality is checked and the file is rewritten if it diverges. This makes upgrades transparent: bump fnord, the next invocation that spawns the pool installs the new script automatically.

Three log outcomes:

- `[embeddings] Installed <path>` — first write, no file on disk.
- `[embeddings] Updated <path>` — existed with different bytes (upgrade/downgrade).
- `[embeddings] Reinstalled after read error <path> (<reason>)` — permissions or similar.

Silent when the on-disk file already matches the compiled-in bytes (the common case).

### `AI.Embeddings.Migration` (`lib/ai/embeddings/migration.ex`)

Detects cross-model state (non-384-dim vectors on disk) on startup of `ask`, `index`, and the read-only commands. When stale, it wipes file/commit/conversation indexes and clears memory embeddings in place, then emits a prominent "memories temporarily unavailable" banner. Re-embedding happens in the background or via `fnord index`.

## Protocol

`embed.exs` runs in **pool mode** (argv `-n <N>`), streaming JSONL over stdin/stdout.

Request:

```json
{"id": "0", "text": "..."}
```

Response:

```json
{"id": "0", "embedding": [0.1, 0.2, ...]}
```

Error:

```json
{"id": "0", "error": "..."}
```

The `Pool` GenServer assigns monotonic integer ids, keeps a `pending` map from id → `from` ref, and replies to callers as responses come back. In-flight concurrency on the `embed.exs` side is bounded by `-n N` (default `max(System.schedulers_online() - 2, 8)`, overridable via `fnord index -w N`). Beyond that, the pool queues on the port's stdin pipe.

## Worker heuristic

`AI.Embeddings.Pool.default_workers/0` returns `max(System.schedulers_online() - 2, 8)`. Rationale: leave two schedulers free so the BEAM itself (plus UI queue, HTTP pool, background indexers) doesn't starve while EXLA is crunching. Floor of 8 so small boxes still get reasonable throughput. `fnord index -w N` clamps at `schedulers_online * 4` — any higher is almost certainly a typo.

## Lifecycle

- `init/1` sets `trap_exit` and triggers `handle_continue(:spawn)`.
- `handle_continue(:spawn)` opens the port via `{:spawn_executable, bash}` → `~/.fnord/embed.sh` → `elixir ~/.fnord/embed.exs -n <workers>`. The wrapper does `env -i` to strip BASH_FUNC_* exports, sets `BUMBLEBEE_CACHE_DIR=~/.fnord/models`, and filters some noisy EXLA stderr.
- Port death (`:closed`, `:exit_status`, `:DOWN`, `:EXIT`) — fail all pending callers with `{:error, :port_died}`, wait 2s, respawn.
- `terminate/2` sets `shutting_down?: true` before calling `Port.close/1` so the subsequent port-death messages skip the warning + respawn paths.

## Gotchas

- **Pool does not cap pending requests.** Back-pressure happens at `embed.exs`'s worker pool, not in the GenServer queue. An unbounded pile of slow embeddings can stack up.
- **The `embed.exs` reader must use `IO.binread/2`, not `IO.stream/2`.** When spawned under an Erlang Port, `IO.stream` doesn't deliver lines reliably. See the inline commentary in `lib/ai/embeddings/script.ex` for the decoupled reader/main-loop rationale.
- **`AI.Splitter` assumes valid UTF-8.** Callers that might feed arbitrary bytes through the summarizer pipeline must `String.valid?/1`-guard first. `Indexer.guard_text/1` is the canonical enforcement point for file content — it returns `{:error, :binary_file}`, which the phase runner counts as `:binary` (distinct from `:skipped`).
- **Upgrades never require a manual step.** The next invocation notices the byte mismatch and rewrites the script.

## Key files

- `lib/ai/embeddings.ex` — public API.
- `lib/ai/embeddings/pool.ex` — GenServer + Port lifecycle.
- `lib/ai/embeddings/script.ex` — bundled script contents + install logic.
- `lib/ai/embeddings/migration.ex` — dimension-mismatch wipe + reindex trigger.

## See also

- [indexing-flow.md](indexing-flow.md) — where embeddings are consumed.
- [storage-layout.md](storage-layout.md) — where embeddings are stored.
- [gotchas.md](gotchas.md) — UTF-8 guard, log tag casing, worker bounds.
