defmodule MCP.Supervisor do
  @moduledoc """
  Supervisor for MCP client instances for the current invocation.
  """
  use Supervisor

  alias MCP.Transport
  alias MCP.FnordClient

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    settings = Settings.new()
    servers = Settings.MCP.effective_config(settings)

    children =
      Enum.map(servers, fn {server, scfg} ->
        {kind, t_opts} = Transport.map(server, scfg)
        # :name registers the Hermes supervisor process; :client_name registers
        # the inner Base GenServer. These MUST be different atoms because the
        # supervisor holds its name while starting children — if Base tries to
        # register the same name, it collides with its own supervisor.
        spec_opts = [
          name: supervisor_name(server),
          client_name: instance_name(server),
          transport: {kind, t_opts}
        ]

        # Use :temporary restart to prevent infinite retry loops
        # Failed MCP servers will be logged but won't crash the app
        Supervisor.child_spec(
          {FnordClient, spec_opts},
          id: {:mcp, server},
          restart: :temporary
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec instance_name(String.t()) :: atom()
  def instance_name(server), do: String.to_atom("mcp:" <> server)

  @spec supervisor_name(String.t()) :: atom()
  def supervisor_name(server), do: String.to_atom("mcp:sup:" <> server)
end
