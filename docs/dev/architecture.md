# Architecture

fnord is an **Elixir escript CLI**. Every invocation boots a fresh BEAM, dispatches one command, and exits. There is no long-lived server process. Within a single invocation, services (embeddings pool, HTTP pool, background indexers, conversation server) run as GenServers under the app's supervisor.

## Startup

Entry point: `lib/fnord.ex:22` (`main/1`). Sequence:

1. Configure logger.
2. `Fnord.start_all/0` — core services (`Services.Globals`, `UI.Queue`, registries). These must exist before CLI parsing because CLI hooks write into them.
3. Load Frob modules (user-defined custom tools, `~/fnord/tools/`).
4. Parse CLI args via Optimus.
5. HTTP pool configuration. Each subsystem gets its own pool to prevent one's work starving another:
   - `:ai` (12 connections) — coordinator + tool calls.
   - `:ai_indexer` (6) — background file/commit/conversation indexing.
   - `:ai_memory` (6) — memory indexer.
   - `:ai_notes` (6) — notes consolidation.
6. `start_config_dependent_services/1` — things that need the parsed config (Approvals, MCP servers).
7. Project resolution (lazy — see below).
8. Dispatch to the subcommand module via `Cmd.perform_command/4` (`lib/cmd.ex:8`).
9. Version check, shutdown.

## Command dispatch

Each subcommand is a module that implements the `Cmd` behaviour:

```elixir
@callback spec() :: keyword()
@callback run(opts, subcommands, unknown) :: any()
@callback requires_project?() :: boolean()
```

Registered in `lib/fnord.ex` (`Cmd.Ask`, `Cmd.Index`, `Cmd.Search`, `Cmd.Memory`, `Cmd.Conversations`, `Cmd.Summary`, `Cmd.Worktrees`, `Cmd.Files`, `Cmd.Config`, etc.). The dispatcher in `lib/cmd.ex:8-10` just calls `cmd.run(opts, subcommands, unknown)`.

### Lazy project resolution

`requires_project?/0` is declarative metadata, not enforcement. Project resolution happens in `set_globals/1` **after** CLI parsing. Order:

1. `--project <name>` on the command line.
2. `Store.ResolveProject.resolve/0` (current-directory detection, `fnord.md` walk-up, etc.).
3. If the command requires a project and none resolved, error out.

This is why most commands can run without an explicit `--project` flag when invoked from inside a project tree — but also why tools that take a project argument need to be ready for nil.

## Escript lifetime

Because each invocation is a fresh BEAM, there's no cache between runs. Anything that needs to persist (embeddings, summaries, memories, conversations) goes through the on-disk store. See [storage-layout.md](storage-layout.md).

Two-phase startup matters for one scenario: `Cmd.Ask` starts the embeddings pool + background indexers explicitly (`lib/cmd/ask.ex:183-194`) before running the coordinator, because they need config parsed first. Other commands that need embeddings call `AI.Embeddings.Pool.ensure_started/0` at their entry point.

## Services running inside an invocation

A typical `fnord ask` session has these GenServers alive concurrently:

- `AI.Embeddings.Pool` — supervises the `embed.exs` Port. See [embeddings-pipeline.md](embeddings-pipeline.md).
- `Services.BackgroundIndexer` — promotes stale file entries one at a time during the session.
- `Services.CommitIndexer` — same but for commits.
- `Services.ConversationIndexer` — same but for conversations.
- `Services.MemoryIndexer` — scans session memories for promotion to project/global. See [memory-system.md](memory-system.md).
- `Services.Conversation` — in-memory state for the active conversation.
- `Services.Task` — per-call work tracking for the coordinator.

A typical `fnord index` session skips the conversation-related servers and runs the indexer phases inline (not as background servers). See [indexing-flow.md](indexing-flow.md).

## Why escript

Escripts are a natural fit for a CLI: single binary, no runtime deps, fast startup. Trade-off: no shared state across invocations, so any warm-cache behavior has to be on disk or re-computed. The embeddings pool is the biggest "warm-up" cost — spawning the BEAM port + loading the MiniLM model takes a few hundred ms on a warm filesystem cache.

## Key files

- `lib/fnord.ex` — main entry point, service startup.
- `lib/cmd.ex` — command dispatch.
- `lib/cmd/*.ex` — per-command modules.
- `lib/services/` — GenServers that outlive a single tool call but not a single invocation.
- `lib/ai/` — agents, tools, model clients, the coordinator.
- `lib/store/` — on-disk store layout.

## See also

- [storage-layout.md](storage-layout.md) — on-disk state.
- [indexing-flow.md](indexing-flow.md) — how `fnord index` works.
- [ask-coordinator.md](ask-coordinator.md) — how `fnord ask` works.
- [gotchas.md](gotchas.md) — invariants to know.
