defmodule MCP.Client.Default do
  @moduledoc """
  Real implementation of `MCP.Client`: talks to the Hermes client GenServers
  registered by `MCP.Supervisor`. All the defensive plumbing for a runtime we
  do not control lives here - registration/aliveness checks before every
  call, rescue/catch around Hermes invocations, and response unwrapping.
  """

  @behaviour MCP.Client

  alias MCP.Supervisor, as: MCPSup

  @impl MCP.Client
  def start_supervisor() do
    # The supervisor is VM-global: any process (the CLI phase, an agent, a
    # tool call) may be first to want MCP, but the stack must survive its
    # initiator. start_link links to the caller, so unlink immediately.
    case Process.whereis(MCPSup) do
      nil ->
        case MCPSup.start_link([]) do
          {:ok, pid} ->
            Process.unlink(pid)
            :ok

          {:error, {:already_started, pid}} ->
            Process.unlink(pid)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  @impl MCP.Client
  def connected?(server) do
    case Process.whereis(MCPSup.instance_name(server)) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @impl MCP.Client
  def list_tools(server) do
    with_connected_client(server, fn client ->
      # Give the server a moment to complete initialization and handshake
      :timer.sleep(1000)

      case Hermes.Client.Base.list_tools(client) do
        {:ok, %Hermes.MCP.Response{result: %{"tools" => tools}}} -> {:ok, tools}
        {:ok, _response} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl MCP.Client
  def get_server_capabilities(server) do
    with_connected_client(server, fn client ->
      case Hermes.Client.Base.get_server_capabilities(client) do
        caps when is_map(caps) -> {:ok, caps}
        nil -> {:ok, %{}}
      end
    end)
  end

  @impl MCP.Client
  def call_tool(server, tool, args, opts) do
    client = MCPSup.instance_name(server)

    try do
      case Hermes.Client.Base.call_tool(client, tool, args, opts) do
        {:ok, %Hermes.MCP.Response{result: result}} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _ -> {:error, "MCP client not available"}
    end
  end

  # Runs `fun` against the server's client atom only when the process is
  # registered and alive; shields the caller from Hermes raising or exiting.
  defp with_connected_client(server, fun) do
    client = MCPSup.instance_name(server)

    case Process.whereis(client) do
      nil ->
        {:error, :not_started}

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            fun.(client)
          rescue
            error -> {:error, {:rescue, error}}
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end
        else
          {:error, :not_alive}
        end
    end
  end
end
