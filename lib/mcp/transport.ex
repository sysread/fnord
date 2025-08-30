defmodule MCP.Transport do
  @moduledoc false

  @typedoc "Hermes transport tuple"
  @type t ::
          {:stdio, keyword()}
          | {:streamable_http, keyword()}
          | {:websocket, keyword()}

  @doc "Convert server config map into a Hermes transport tuple"
  @spec map(map()) :: {atom(), keyword()}
  def map(%{"transport" => "stdio"} = cfg) do
    {:stdio,
     [
       command: cfg["command"],
       args: cfg["args"] || [],
       env: cfg["env"] || %{}
     ]}
  end

  def map(%{"transport" => "streamable_http"} = cfg) do
    {:streamable_http,
     [
       base_url: cfg["base_url"],
       headers: cfg["headers"] || %{}
     ]}
  end

  def map(%{"transport" => "websocket"} = cfg) do
    {:websocket,
     [
       base_url: cfg["base_url"],
       headers: cfg["headers"] || %{}
     ]}
  end
end
