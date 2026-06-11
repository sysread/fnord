# Architecture

fnord is an **Elixir escript CLI**. Every invocation boots a fresh BEAM, dispatches one command, and exits. There is no long-lived server process. Within a single invocation, services (embeddings pool, HTTP pool, background indexers, conversation server) run as GenServers under the app's supervisor.

## Startup

Entry point: `lib/fnord.ex:22` (`main/1`). Sequence:

1. Configure logger.
2. `Fnord.Instance.start_link/1` — checks out the app instance: installs the main process as the `Services.Globals` root and starts the full service roster. This happens before CLI parsing because CLI hooks write into Globals and log via `UI.Queue`. Services read config at call time, so booting them before `set_globals/1` is safe.
3. Load Frob modules (user-defined custom tools, `~/fnord/tools/`).
4. Parse CLI args via Optimus.
5. HTTP pool configuration. Each subsystem gets its own pool to prevent one's work starving another:
   - `:ai_api` — coordinator + tool calls.
   - `:ai_indexer` — background file/commit/conversation indexing.
   - `:ai_memory` — memory indexer.
   - `:ai_notes` — notes consolidation.
6. Project resolution (lazy — see below).
7. Dispatch to the subcommand module via `Cmd.perform_command/4` (`lib/cmd.ex:8`).
8. Version check, shutdown.

## HTTP transport

All network I/O funnels through `Http.Client` (`lib/http/client.ex`), the single seam over HTTPoison/hackney. `Http` (retrying JSON helpers used by `AI.Endpoint` and `Util`) and the MCP OAuth/discovery modules call `Http.Client.impl().get/post/head` rather than HTTPoison directly. `impl/0` resolves the `:http_client` Globals key (same dispatch pattern as `:indexer`), defaulting to the HTTPoison passthrough in production. `Fnord.TestCase` points the key at a Mox mock with no default stub, so any test code path that tries to reach the network fails loudly instead of hitting the wire.

One layer up, `AI.CompletionAPI` is the model-call boundary: `AI.Completion`'s loop calls `AI.CompletionAPI.impl().get/6`, resolved via the `:completion_api` Globals key. Everything below that contract is wire concerns (payload shape, auth, retry); everything above it is the completion loop. Tests feed canned model responses through the real loop with `Fnord.TestCase.canned_completion/1` instead of mocking `AI.Completion` itself - the loop's message handling, compaction, and error mapping stay under test.

At the top, `AI.Agent.Dispatcher` is the agent-invocation boundary: `AI.Agent.get_response/2` runs its bookkeeping (name checkout, task wrapping, HTTP pool propagation) and then calls `AI.Agent.Dispatcher.impl().dispatch(impl_mod, args)`, resolved via the `:agent_dispatcher` Globals key. Tests that treat a sub-agent as an opaque collaborator (e.g. the edit tool's Patcher, the conversation summarizer) canned-respond per agent module with `Fnord.TestCase.canned_agent/1`. Unlike the two lower seams, tests do NOT default this key to a mock - the default stays the real dispatcher so most tests exercise real agents driven by canned model responses, and the no-unmocked-network guarantee already lives below.

## Git subprocess boundary

`GitCli`, `GitCli.Worktree`, and `GitCli.Worktree.Review` are **facades**: each is a behaviour whose public functions delegate through `impl/0` (Globals keys `:git_cli`, `:git_worktree`, `:git_review`), defaulting to the real implementation in the sibling `Default` module (`System.cmd("git", ...)` wrappers). This seam uses facade delegation instead of the caller-side `Module.impl().fn()` convention of the narrow seams above because the git API is wide (~45 functions) with ~100 call sites - the facade keeps callers untouched.

Two properties matter for tests. First, the `Default` modules route calls to *public siblings* back through their facade (e.g. `has_changes_to_merge?` calls `GitCli.Worktree.has_uncommitted_changes?`, not a local function), so a test double on the Globals key intercepts nested calls exactly the way `:meck` passthrough did. Second, tests do NOT point these keys at mocks by default - real git stays in place. Tests that script git state opt in via `Fnord.TestCase.mock_git_cli/0` / `mock_git_worktree/0` / `mock_git_review/0`, which install the Mox mock pre-stubbed (`stub_with`) to pass through to `Default`; the test then overrides individual functions with `Mox.stub`.

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
2. `Store.ResolveProject.resolve/1` (current-directory detection, `fnord.md` walk-up, etc.).
3. If the command requires a project and none resolved, error out.

This is why most commands can run without an explicit `--project` flag when invoked from inside a project tree — but also why tools that take a project argument need to be ready for nil.

## Escript lifetime

Because each invocation is a fresh BEAM, there's no cache between runs. Anything that needs to persist (embeddings, summaries, memories, conversations) goes through the on-disk store. See [storage-layout.md](storage-layout.md).

Some services boot lazily rather than with the instance: `Cmd.Ask` starts the embeddings pool + background indexers explicitly (`lib/cmd/ask.ex:183-194`) before running the coordinator, because they need config parsed first. Other commands that need embeddings call `AI.Embeddings.Pool.ensure_started/0` at their entry point.

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

## Tree-scoped services (instance checkout)

Services start unnamed and register their pid for the *current process tree* via `Services.Instance`, which piggybacks on `Services.Globals` root resolution: lookups walk `:"$ancestors"` to the tree's root, so two trees in one BEAM each see their own copy, and registrations are wiped automatically when the root dies. (VM-global atom names would work for production's one-tree-per-BEAM shape, but would force every test in the suite to share one copy of each service.)

`Fnord.Instance` is the single boot path: it installs the calling process as a Globals root, applies a config keyword list as tree-local overrides, and supervises the service roster (`max_restarts: 0` - a service death kills the instance and its owner, matching bare-link crash semantics). Production checks out one instance owned by the main process; every test checks out its own in `Fnord.TestCase` setup; tests can also stand up additional instances side by side.

Caveats inherited from `:"$ancestors"` resolution: raw-`spawn`ed processes carry no ancestry and cannot resolve any instance (use `Task` or `Services.Globals.Spawn`, which propagates the root via pdict), and processes spawned through a supervisor owned by a *different* (or dead) tree resolve the wrong root.

Tree-scoped: `UI.Queue`, `UI.Tee`, `Services.Once`, `Services.Notes`, `Services.Conversation.Interrupts`, `Services.BackupFile`, `Services.TempFile`, `Services.FileCache`, `Services.NamePool`, `Services.Approvals`, `Services.Approvals.Gate`, `Services.Task`, `Services.MemoryIndexer`, `AI.Embeddings.Pool`, `MCP.Tools` (its tool_name => module index is per-tree; the dynamically created modules remain VM-global). Still VM-global: the MCP stack (`MCP.ClientRegistry`, hermes client/supervisor names - hermes requires atom names). The formerly global `Services.TaskSupervisor` was unused and has been deleted.

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
