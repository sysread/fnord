defmodule Services.FileCache do
  @moduledoc """
  GenServer-backed file cache used by AI tools and other services that need
  to read file contents from the project workspace.

  Responsibilities:
  - Store {path -> %{sha: sha, content: content}}
  - Provide lookup and insert APIs
  - Handle concurrent access safely via GenServer

  The cache is intentionally simple: it validates freshness by recomputing a
  sha256 over the file contents when doing a lookup and updates the stored
  entry when a mismatch is detected.
  """

  use GenServer

  @name __MODULE__

  @type entry :: %{sha: String.t(), content: String.t()}

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @name))
  end

  @doc """
  Lookup a cached file by absolute path. Returns {:ok, content} or :miss. The
  caller should provide a fetch_fun that will be called to obtain actual file
  contents when the cache is missing or stale.
  """
  @spec get_or_fetch(String.t(), (-> {:ok, String.t()} | {:error, any()})) ::
          {:ok, String.t()}
          | {:error, any()}
          | :miss
  def get_or_fetch(path, fetch_fun) do
    GenServer.call(@name, {:get_or_fetch, path, fetch_fun}, :infinity)
  end

  @doc "Directly put content into the cache for a path."
  @spec put(String.t(), String.t()) :: :ok
  def put(path, content) do
    GenServer.cast(@name, {:put, path, content})
  end

  # ----------------------------------------------------------------------------
  # Server callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_fetch, path, fetch_fun}, _from, state) do
    case Map.get(state, path) do
      %{sha: sha, content: content} ->
        # validate current content by calling fetch_fun
        case fetch_fun.() do
          {:ok, new_content} ->
            new_sha = sha256(new_content)

            if new_sha == sha do
              {:reply, {:ok, content}, state}
            else
              new_state = Map.put(state, path, %{sha: new_sha, content: new_content})
              {:reply, {:ok, new_content}, new_state}
            end

          {:error, _} ->
            # fallback to cached content on read error
            {:reply, {:ok, content}, state}
        end

      nil ->
        case fetch_fun.() do
          {:ok, content} ->
            entry = %{sha: sha256(content), content: content}
            {:reply, {:ok, content}, Map.put(state, path, entry)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:put, path, content}, state) do
    entry = %{sha: sha256(content), content: content}
    {:noreply, Map.put(state, path, entry)}
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
