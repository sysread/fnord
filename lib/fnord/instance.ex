defmodule Fnord.Instance do
  @moduledoc """
  A checked-out application instance: a supervision tree carrying its own
  config scope and its own copies of fnord's services.

  `start_link/1` installs the *calling* process as a `Services.Globals` root,
  applies the given config as tree-local overrides, and starts the service
  roster under a supervisor. Everything spawned beneath the caller resolves
  config and services from that root, so multiple instances in one BEAM
  (e.g. tests) are mutually invisible.

  The caller owns the instance: when it exits, the supervisor (and all
  services under it) shut down with it, and `Services.Globals` wipes the
  root's config overrides and service registrations.

  This is the single boot path: production (`Fnord.main/1`) and tests
  (`Fnord.TestCase` setup) both check out an instance. NamePool and
  Approvals read config at call time (their inits read nothing), so no
  second config-dependent boot phase exists. Not in the roster: per-conversation servers
  (`Services.Task`, started by `Cmd.Ask` with a conversation pid),
  `Services.MemoryIndexer` (session-lazy, started by `Cmd.Ask`), `UI.Tee`
  (started only under `--tee`), and the MCP stack (atom-named by the
  hermes library; see docs/dev/gotchas.md).
  """

  use Supervisor

  @doc """
  Check out an instance owned by the calling process.

  Options:
  - `:config` - keyword list of `:fnord` config applied as tree-local
    overrides before any service starts, so services boot with their
    invocation config already resolved.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    # Services.Globals is the one legitimately VM-global service: it owns the
    # ETS tables that all roots and registrations live in. Its start_link
    # tolerates already_started, so instance checkouts after the first are
    # no-ops here.
    {:ok, _} = Services.Globals.start_link()
    {:ok, _} = Application.ensure_all_started(:briefly)
    :ok = ensure_mcp_client_registry()
    Services.Globals.install_root()
    Services.Globals.put_all_env(:fnord, Keyword.get(opts, :config, []))
    Supervisor.start_link(__MODULE__, :ok)
  end

  # The MCP client registry is VM-global by necessity (the hermes library
  # registers clients under atom-derived names; see docs/dev/gotchas.md).
  # Tolerate re-boots within one BEAM.
  defp ensure_mcp_client_registry() do
    case Registry.start_link(keys: :unique, name: MCP.ClientRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @impl true
  def init(:ok) do
    children = [
      # UI.Queue first: everything else may log during startup.
      %{id: UI.Queue, start: {UI.Queue, :start_link, [[]]}},
      %{id: Services.Once, start: {Services.Once, :start_link, []}},
      %{id: Services.Notes, start: {Services.Notes, :start_link, [[]]}},
      %{
        id: Services.Conversation.Interrupts,
        start: {Services.Conversation.Interrupts, :start_link, [[]]}
      },
      %{id: Services.BackupFile, start: {Services.BackupFile, :start_link, [[]]}},
      %{id: Services.TempFile, start: {Services.TempFile, :start_link, [[]]}},
      %{id: Services.FileCache, start: {Services.FileCache, :start_link, [[]]}},
      %{id: Services.NamePool, start: {Services.NamePool, :start_link, [[]]}},
      %{id: Services.Approvals, start: {Services.Approvals, :start_link, [[]]}},
      %{id: Services.Approvals.Gate, start: {Services.Approvals.Gate, :start_link, [[]]}},
      %{id: MCP.Tools, start: {MCP.Tools, :start_link, [[]]}}
    ]

    # max_restarts: 0 preserves the historical bare-link semantics: any
    # service termination is fatal to the instance (and so to its owner).
    # Tests fail loudly instead of running against a silently-restarted,
    # state-wiped service; prod exits as it always has. Deliberate state
    # resets are API calls (e.g. Services.Approvals.reset_session/0), not
    # process restarts.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 0)
  end
end
