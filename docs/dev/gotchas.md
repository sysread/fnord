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

## 9. Single-phase service startup via Fnord.Instance

All services boot in one pass through `Fnord.Instance.start_link/1`
(production: `Fnord.main/1` before CLI parsing; tests: `Fnord.TestCase`
setup after config overrides are applied). This works because services do
not read config at init - they resolve it at call time through
`Services.Globals` (e.g. `Services.Approvals.impl_for/1`, NamePool's
nomenclater check). If you add a service whose `init/1` reads config, it
will see unparsed defaults in production - resolve config at call time
instead, or redesign the boot. MCP is still started lazily on first tool
access. The instance supervisor runs with `max_restarts: 0`: any service
termination kills the instance and its owner, preserving the historical
bare-link crash semantics - reset state through service APIs (e.g.
`Services.Approvals.reset_session/0`), never by stopping/restarting a
roster service.

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

## 21. UI.Output.TestStub.puts leaks to the ExUnit progress display

`UI.Output.TestStub.puts/1` calls `IO.puts` — it is intentionally capturable via
`ExUnit.CaptureIO`, but it prints to stdout if not suppressed. Any test that calls
`Cmd.*.run/3` without suppression will interrupt the dot stream in `make check` output.

Two patterns, depending on what the test needs:

**Stub silent** — when asserting on the return value, not the printed text:

```elixir
setup do
  stub(UI.Output.Mock, :puts, fn _msg -> :ok end)
  :ok
end
```

**capture_all** — when asserting on what was printed (`Fnord.TestCase` provides `capture_all/1`):

```elixir
{output, _stderr} = capture_all(fn -> Cmd.SomeCmd.run(%{}, [:sub], []) end)
assert output =~ "expected"
```

`make check` is the detection signal: leaked output appears as raw text between progress dots.
See `test/README.md` for the full decision table.

## 22. AI.Completion has a tool-round cap

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

## 23. External skills that delegate to fnord cause infinite recursion

Claude Code and Cursor skills are loaded from `~/.claude/skills/` and
`~/.cursor/skills/` (plus per-project equivalents) and surfaced to fnord's
coordinator through `run_skill`. A common pattern is a shim skill - e.g.
`~/claude-shared/skills/review/SKILL.md` - whose body tells the host model
to shell out to `fnord ask -W . -q "..."`. The shim exists to delegate
Claude/Cursor invocations into fnord.

When fnord itself loads such a skill, the agent dutifully runs the body's
instructions and shells out to a fresh `fnord ask` process. That process
loads the same skill, and so on - infinite recursion (in practice, halted
by the permission prompt for the nested shell command, but it still wastes
a full turn and confuses the user).

`ExternalConfigs.Loader.load_claude_skills/1` and `load_cursor_skills/1`
filter these skills out by checking
`ExternalConfigs.Skill.fnord_skip`. Two detection paths:

1. **Explicit opt-out**: `fnord_skip: true` in the SKILL.md frontmatter.
   This is the preferred path; skills that exist to bridge another tool
   into fnord should declare it.
2. **Body scan fallback**: any skill body containing `fnord ask` or
   `fnord-dev ask` (word-bounded, case-sensitive) is filtered with reason
   `:body_invokes_fnord` so that mis-configured shims still cannot recurse.

An explicit `fnord_skip: false` in the frontmatter overrides the body scan.
Use this only when you know the body legitimately references the command
in prose and the skill is not a recursion hazard.

If you add new ways for skills to call back into fnord (a new subcommand,
a different binary name), update the regex in
`lib/external_configs/skill.ex` (`@fnord_invocation_re`) and add a
regression test.

## 24. Responses-API strict mode: every property must be in `required`

OpenAI's `/v1/responses` structured-output validator rejects any JSON
schema where the `required` array doesn't list **every** key in
`properties`. Chat Completions used to silently accept partial-required
schemas; the Responses API surfaces it as:

```
Invalid schema for response_format 'X': In context=(), 'required' is
required to be supplied and to be an array including every key in
properties. Missing 'Y'.
```

The error kills the call after retries, and downstream agents (reviewer
pipeline, task planner, task implementor, patcher) have no graceful
fallback. Symptom: `reviewer_tool` reports a schema error mid-pipeline
even though the caller did everything right.

Genuine optionality is expressed via **nullable union types** AND the
key being in `required`:

```elixir
checkpoint: %{type: ["boolean", "null"], description: "..."}
```

Consumer code must then handle nil explicitly:

```elixir
# Wrong: Map.get default fires on absent keys, not on nil values.
cp? = Map.get(decoded, :checkpoint, false)

# Right:
cp? = Map.get(decoded, :checkpoint) == true
```

The meta-test at `test/ai/agent/strict_schemas_test.exs` walks every
`@response_format` we expose (via `__response_format__/0` or
`__response_formats__/0` accessors on each agent module) and asserts the
strict rule recursively. When you add a new agent with a json_schema
response_format, register it in that test's `@single_accessor` or
`@multi_accessor` list and provide the accessor function, otherwise the
schema will trip the validator at first runtime call.

## 25. LLM tool args: type-default placeholders, not JSON null

OpenAI's tool-call generator often emits **type-default placeholders** for
optional params instead of omitting them: `""` for strings, `0` for
integers, `[]` for arrays. From the Elixir side, those values are all
truthy - only `nil` and `false` are falsy. So a `Enum.filter(fn {_, v} -> v end)`
that intends "keep only provided fields" silently keeps the placeholders.

When the tool's contract is *"pass at most one of A, B, C,"* this produces
an unrecoverable retry loop: the model thinks it sent just `A`, the tool
sees `A=set, B="", C=0` and rejects the call as "all three set," the
model's chain-of-thought reads the error and resends the same shape.

`AI.Tools.Reviewer.normalize_target_args/1` (`lib/ai/tools/reviewer.ex`)
uses a `present?/1` predicate that treats `nil`, `""`, `0`, and `[]` as
absent. Any tool that exposes mutually-exclusive optional params should do
the same; never filter on bare Elixir truthiness when the inputs come from
an LLM tool call.

When a mutex tool DOES reject multi-set input, the error message should
include the actual values received (e.g. `branch="responses", pr=0,
range=""`), not just the names of the set fields - the model needs to see
*what* tripped the mutex to know which fields it's accidentally populating
with placeholders.

## 26. `AI.Model.web_search()` is a model, not a switch

Under the legacy Chat Completions API, OpenAI exposed web search through a
dedicated SKU (`gpt-5-search-api`). Selecting that model was sufficient -
the model itself knew how to search. Under the Responses API, web search
is a tool entry (`%{type: "web_search"}` in the `tools` array) that any
model can use.

`AI.Model.web_search()` now returns a **normal** model. Calling it without
also passing `web_search?: true` to `AI.Completion.get/1` produces a
completion that has no access to web search. The two existing call sites
that need search (`AI.Tools.WebSearch.perform_search/1` and
`AI.Tools.SelfHelp.Docs.search_docs/1`) set both.

If you add a new caller, the contract is: pick `model: AI.Model.web_search()`
**and** pass `web_search?: true`. Missing the second half is a silent
degradation - the call still succeeds, it just runs without search.

The wire payload is built in `AI.CompletionAPI.build_tools/2`
(`lib/ai/completion_api.ex`). Use the canonical `web_search` name;
`web_search_preview` is the legacy form retained by OpenAI for backwards
compatibility only.

## 27. lowfat wrapping must never touch a stdin-consuming command

`AI.Tools.Cmd` optionally wraps command execution with `lowfat` to filter
output (see `docs/dev/tool-system.md`). lowfat is an exec wrapper that spawns
the child with a **closed stdin** and is **lossy by design**. Both properties
constrain where it may be applied:

- A `|` pipeline stage receives data on stdin; wrapping it would feed the child
  a closed stdin and break the command.
- A non-final stage's output feeds the next command; filtering it would corrupt
  the pipe. Only output that reaches the *model* may be filtered.

`lowfat_eligible?/3` encodes this as `input == nil and (op == "&&" or rest == [])`.
Anyone touching `run_pipeline/5` or `shell_out/4` must preserve the invariant:
wrap only when stdin is empty **and** the output is the model-facing result.
Wrapping a `|` stage is a correctness bug, not a perf regression - the command
will silently misbehave.

The kill switch is `FNORD_NO_LOWFAT=1`. The test suite sets it by default
(`Fnord.TestCase`) so cmd_tool tests see raw output regardless of whether
`lowfat` is installed; `test/ai/tools/cmd/lowfat_test.exs` opts back in with a
PATH-prepended stub.

## 28. Broken doc autolinks fail only the docs build, not compile/test/dialyzer

ExDoc autolink resolution happens only when the docs are generated, never
during compilation. A backtick reference inside an `@moduledoc`/`@doc` string
to a function that is undefined, private, or wrong-arity passes
compile/test/dialyzer cleanly - the compiler does **not** resolve
`` `Mod.fun/arity` `` references in doc strings.

This was invisible locally until `make check` gained the `docs-check` target
(`mix docs --warnings-as-errors`); previously `check` was just
`compile + test + dialyzer + md-lint` and the only gate was CI's separate
"build docs" step. The local `docs-check` now mirrors that CI gate, so a broken
autolink fails `make check` before it reaches CI.

Footgun: any `` `Name.fun/arity` `` in a docstring is an autolink target. If
the symbol doesn't exist (e.g. it's a behaviour callback, not a function), the
build fails. Reference callbacks with the `` `c:Mod.fun/arity` `` form. A
wildcard like `` `AI.Tools.<*>.spec/0` `` is not a valid reference shape, so
ExDoc leaves it alone - that is why such forms don't warn.

## 29. MCP OAuth: redirect_uri must be byte-identical across the whole flow

The OAuth redirect_uri appears in three requests: dynamic client
registration (`MCP.OAuth2.Registration` via `Discovery`), the authorization
request (`MCP.OAuth2.Adapter.Default`), and the token exchange
(`Cmd.Config.MCP.Login.await_callback` -> `Client.exchange_code`). RFC 6749
§4.1.3 requires the token-exchange value to match the authorization value
**byte for byte** - `http://localhost:N/callback` and
`http://127.0.0.1:N/callback` are a mismatch even though they hit the same
loopback. fnord standardizes on the `localhost` host form at every site;
anyone touching one site must keep all three in lockstep. (The loopback
HTTP server itself binds `127.0.0.1` - that's the *bind address*, not the
redirect_uri, and is unrelated.)

Related: the MCP authorization spec layers RFC 8707 on OAuth 2.1 - the
client must send `resource=<canonical MCP server URI>` on the authorization
request, code exchange, and refresh. fnord threads the server's `base_url`
into `MCP.OAuth2.Client` as the optional `:resource` config key
(`Cmd.Config.MCP.Login.fetch_oauth` and `MCP.OAuth2.Bridge.refresh`).
Servers like Linear hard-fail (opaque "internal error" page after consent)
when it is missing; servers that predate RFC 8707 ignore it.

## 30. MCP http transport: Hermes mangles a base_url that carries the path

Hermes's StreamableHTTP transport computes the request URL as
`URI.append_path(base_url, mcp_path)` with `mcp_path` defaulting to `"/"`
(not `"/mcp"` as one might assume). A config whose `base_url` already
contains the endpoint path - `https://mcp.linear.app/mcp` - therefore gets
requested as `.../mcp/`, and servers route the trailing-slash form as a
distinct (404) path. The failure is invisible in a normal session because
`Services.MCP.discover_once/1` silently skips servers whose handshake
fails - the server just doesn't appear in the `MCP tools:` startup line.
`FNORD_DEBUG_MCP=1 fnord config mcp check` exposes the real URL and
status code.

`MCP.Transport.split_endpoint/1` prevents this: with an explicit
`mcp_path` the Hermes append semantics apply (base_url = origin); without
one, the configured base_url is split into origin + path so the request
hits exactly the URL the user configured. Keep that contract in mind when
touching transport config handling: "no mcp_path" means *the base_url IS
the endpoint*, not "use a default path".

## 31. UI.Queue queued interacts execute inside the queue process - nesting must not call back in

`UI.Queue`'s queued interact path (`handle_call({:interact, fun}, ...)`)
runs the fun inline in the queue's own process, and `exec/1` plants the
interaction-context token in the queue process's pdict. A nested
`UI.interact` from inside that fun therefore sees `in_ctx?` true and takes
the fast path - which must not `GenServer.call` the queue (`:pause_logs`,
or anything else): a call-to-self from within `handle_call` crashes with
`:calling_self`. `interact/3` special-cases `to_pid(server) == self()` to
a bare `exec/1`; no pause is needed there because the GenServer can't
process concurrent `{:log, ...}` calls while it's busy executing the fun.
This nesting is not exotic - `fnord frobs call` wraps its whole
parameter-prompt loop in `UI.interact` and each per-parameter
choose/prompt interacts again. The same constraint applies to any new
GenServer.call-based coordination added to the fast path, and to UI
helpers invoked from interact funs (e.g. a `UI.Queue.log` from inside a
queued interact fun would hit the same wall - it has no self-call guard).

## 32. Tree-scoped services resolve via $ancestors only - raw spawns and cross-tree supervisors see nothing

`Services.Instance` (and `Services.Globals` generally) resolves the
current tree's root by walking `:"$ancestors"`, which only
proc_lib-spawned processes (GenServer, Supervisor, Task, Agent) carry.
Two consequences:

- A raw-`spawn`ed process has no ancestry: it resolves no root, so
  tree-scoped service calls (`Services.Once.set/2`, etc.) raise and
  config reads fall back to defaults. Use `Task`/`proc_lib` spawns for
  anything that needs the tree's services or config.
- A process spawned through a supervisor owned by a *different* tree
  inherits that tree's ancestry, not the caller's. A globally-named,
  shared Task.Supervisor is the canonical trap: it would be started by
  the first tree that boots services (in tests, the first test), so
  tasks spawned through it would resolve a dead root. The unused
  `Services.TaskSupervisor` was deleted for exactly this reason - if
  you need supervised tasks, start a Task.Supervisor inside your own
  tree (as `Services.MemoryIndexer.init/1` does) or use
  `Services.Globals.Spawn`, which propagates the root via pdict.
  `$callers` (which Task sets) is NOT consulted by root resolution.

Related: registry entries must be looked up with
`Services.Globals.get_override/3`, not `get_env/3` - the no-override
path of `get_env/3` falls back to `Application.get_env/3`, which
deprecates (and will eventually reject) non-atom keys like
`{:instance_service, module}`.

## 33. Never check-then-create a named ETS table - use Globals.ensure_shared_table

The bare pattern (`if :ets.info(name) == :undefined, do: :ets.new(name, ...)`)
has two failure modes under concurrent tests: the check-then-act races (both
callers see :undefined; the loser raises "table name already exists" - under
the instance supervisor's max_restarts: 0, that kills the whole instance and
fails an unrelated test), and the table is owned by whichever process created
it, so it silently vanishes when that process exits (under per-test
instances: when the first test to touch it finishes).
`Services.Globals.ensure_shared_table/2` serializes creation through the
Globals GenServer and makes Globals - which lives for the whole VM - the
owner. Both prior offenders (Services.Notes' :notes_status counter,
AI.Tools.Cmd's tool-availability memo) now go through it.

## 34. Never lazily start a named process linked to the caller - put it in the instance roster

The pattern `case Process.whereis(Name) do nil -> start_link(); _ -> :ok end`
fails the same way as bare named-ETS creation (item 33), plus one worse:
`start_link` links the VM-globally-named process to whichever caller got
there first. Under per-test instances that is some arbitrary test process,
and the "global" server silently dies when that test finishes - concurrent
tests then crash with "no process" mid-call, seed-dependently. In prod the
same shape means a transient task can own (and take down) a supposedly
session-long server. `MCP.Tools` was the last offender: its lazy
`ensure_started` is gone and it now boots with the `Fnord.Instance` roster,
registered through `Services.Instance` like every other tree-scoped service.
If a service needs to exist, it belongs in the roster; if state must outlive
the tree, it belongs to Globals (item 33).

## 35. GitCli Default impls must call public siblings through the facade

`GitCli`, `GitCli.Worktree`, and `GitCli.Worktree.Review` are facades over
`*.Default` implementation modules (Globals keys `:git_cli`, `:git_worktree`,
`:git_review`). Inside a `Default` module, a call to a public sibling must be
facade-qualified (`GitCli.Worktree.has_uncommitted_changes?(path)`), never a
bare local call - the facade hop is what lets a test double installed on the
Globals key intercept nested calls, matching the `:meck` passthrough
semantics the test suite was written against. A bare local call compiles and
works in prod, but silently bypasses test doubles: a test that stubs
`has_uncommitted_changes?` and exercises `has_changes_to_merge?` would hit
real git instead of the stub. Private helpers stay local; only public
functions route through the facade.

## 36. Mox-mocked facades cannot be called from an ad-hoc GenServer's init in async tests

Async tests run Mox in private mode, and `Fnord.TestCase.allow_service_mocks/1`
grants allowances only to processes in the `Services.Instance` roster. A
GenServer started ad hoc by a test (`Services.CommitIndexer.start_link/1` in
its test, for example) executes `init/1` in its own process *before*
`start_link` returns - there is no moment at which the test can grant it an
allowance. If that init path calls a Mox-backed facade (GitCli, UI.Output,
etc.), the call dies with a Mox ownership error, but only under async
scheduling. Such tests must stay `async: false` (global Mox mode) and say so
in a comment. Tasks are different: they inherit `$callers`, which Mox
consults, so spawned-task mock calls are fine in async tests.

## 37. AI.Tools.get_project/0 rejects projects with missing or empty store dirs

`AI.Tools.get_project/0` layers `Store.Project.exists_in_store?/1` on top of
`Store.get_project/0`, and `exists_in_store?` returns false for a store
directory that is missing OR empty (a defensive check against a historical
partial-delete bug). `Fnord.TestCase.mock_project/1` saves project settings
but does not populate the store, so any code path that resolves the project
through `AI.Tools.get_project/0` (the canonical file accessor
`get_file_contents*`, most file tools) fails with `:project_not_found` in a
fresh mock project. Tests seed it with
`File.mkdir_p!(Store.Project.files_root(project))` - the wildcard sees the
subdirectory and the project becomes resolvable. Code paths that use
`Store.get_project/0` directly (search, commit index) do not need this.

## 38. Running the full ask flow in a test wakes the ConversationIndexer's summary agent

`Cmd.Ask.run/3` starts the background indexers for real. The
ConversationIndexer resolves its candidate list at startup, so a test that
seeds a conversation file *before* calling `run/3` (e.g. to exercise
`--follow`) will see that conversation summarized mid-test - through the
same `:agent_dispatcher` seam as the coordinator, but with
`AI.Agent.ConversationSummary` as the impl module. A `canned_agent/1` fun
that only matches `AI.Agent.Coordinator` dies with a FunctionClauseError
inside the indexer's task, which the task link propagates back into the
test. Can both agents (see `canned_coordinator/1` in `test/cmd/ask_test.exs`).
Conversations created *during* the run (the normal save path) are not
affected: the candidate list was resolved before they existed.

## 39. GitCli.is_git_repo_at?/1 is not a commit-indexer-specific probe

`Services.CommitIndexer` gates its commit-history scan on
`GitCli.is_git_repo_at?/1`, which makes it tempting to stub as a "did the
commit indexer run?" probe. But the file-index scan consults the same
callback per scan via `GitCli.Default.resolve_default_branch/1`
(`Source.hash`/`Source.exists?`), so the probe fires from
`Services.BackgroundIndexer` too. `GitCli.commit_shas/2` is only reachable
through the commit index - probe that instead.
