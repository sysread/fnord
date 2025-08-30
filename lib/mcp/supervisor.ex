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
    cfg = Settings.MCP.effective_config(settings)

    children =
      if cfg["enabled"] do
        Enum.map(cfg["servers"], fn {server, scfg} ->
          {kind, t_opts} = Transport.map(scfg)
          spec_opts = [name: instance_name(server), transport: {kind, t_opts}]
          Supervisor.child_spec({FnordClient, spec_opts}, id: {:mcp, server})
        end)
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec instance_name(String.t()) :: atom()
  def instance_name(server), do: String.to_atom("mcp:" <> server)
end
