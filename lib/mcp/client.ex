defmodule MCP.Client do
  @moduledoc """
  Facade for the Hermes MCP client runtime: the VM-global `MCP.Supervisor`
  and the per-server Hermes client GenServers it supervises.

  Every Hermes touch point in fnord routes through this module so tests can
  substitute a `Mox` double (`Fnord.TestCase.mock_mcp_client/0`) instead of
  booting real server transports. The real implementation lives in
  `MCP.Client.Default`.

  Callbacks are keyed by *server name* (the key in `Settings.MCP` config),
  not by client pid or atom - resolving the registered process for a server
  is an implementation detail of the runtime.
  """

  @doc """
  Starts the MCP supervisor (idempotent) and detaches it from the caller.
  The Hermes stack is VM-global and must outlive the process that happened
  to trigger it; see `MCP.Client.Default` for the unlink rationale.
  """
  @callback start_supervisor() :: :ok | {:error, term()}

  @doc "True when the server's client process is registered and alive."
  @callback connected?(server :: String.t()) :: boolean()

  @doc "Lists the tools advertised by a connected server."
  @callback list_tools(server :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc "Fetches the capabilities map negotiated with a connected server."
  @callback get_server_capabilities(server :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Invokes a tool on a connected server, returning the unwrapped result."
  @callback call_tool(server :: String.t(), tool :: String.t(), args :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  def impl() do
    Services.Globals.get_env(:fnord, :mcp_client, MCP.Client.Default)
  end

  @spec start_supervisor() :: :ok | {:error, term()}
  def start_supervisor(), do: impl().start_supervisor()

  @spec connected?(String.t()) :: boolean()
  def connected?(server), do: impl().connected?(server)

  @spec list_tools(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(server), do: impl().list_tools(server)

  @spec get_server_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def get_server_capabilities(server), do: impl().get_server_capabilities(server)

  @spec call_tool(String.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(server, tool, args, opts), do: impl().call_tool(server, tool, args, opts)
end
