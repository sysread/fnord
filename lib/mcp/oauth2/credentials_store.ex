defmodule MCP.OAuth2.CredentialsStore do
  @moduledoc """
  Minimal credentials store for OAuth2 tokens.
  - JSON file at `~/.fnord/credentials.json`
  - Atomic writes (`.tmp` + rename), final perms set to 0600
  - Per-server entries under the `"servers"` key

  MVP: no encryption; keep tokens out of logs; caller is responsible for locking if needed.
  """

  @default_rel ".fnord/credentials.json"

  @spec path() :: String.t()
  def path do
    Path.join(Settings.get_user_home(), @default_rel)
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def read(server) do
    with {:ok, %{"servers" => servers}} <- read_all(),
         entry when is_map(entry) <- Map.get(servers, server) do
      {:ok, entry}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(server, token_map) when is_map(token_map) do
    base =
      case read_all() do
        {:ok, m} -> m
        _ -> %{}
      end

    servers = base |> Map.get("servers", %{}) |> Map.put(server, token_map)
    updated = %{"servers" => servers, "last_updated" => System.os_time(:second)}
    atomic_write(updated)
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(server) do
    base =
      case read_all() do
        {:ok, m} -> m
        _ -> %{}
      end

    servers = base |> Map.get("servers", %{}) |> Map.delete(server)
    updated = %{"servers" => servers, "last_updated" => System.os_time(:second)}
    atomic_write(updated)
  end

  @spec read_all() :: {:ok, map()} | {:error, term()}
  def read_all do
    p = path()

    case File.read(p) do
      {:ok, body} -> Jason.decode(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, e} -> {:error, e}
    end
  end

  defp atomic_write(map) do
    p = path()
    dir = Path.dirname(p)
    tmp = p <> ".tmp"

    File.mkdir_p!(dir)
    body = Jason.encode!(map, pretty: true)

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, p),
         :ok <- File.chmod(p, 0o600) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end
end
