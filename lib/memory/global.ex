defmodule Memory.Global do
  @moduledoc """
  Global memory storage implementation for the `Memory` behaviour.
  Memories are stored as JSON files in `~/.fnord/memory`.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour Memory

  @impl Memory
  def init() do
    with {:ok, _path} <- ensure_storage_path() do
      drop_old_storage()
      :ok
    end
  end

  @impl Memory
  def list() do
    with {:ok, files} <- File.ls(storage_path()) do
      files
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn file ->
        file
        |> Path.rootname()
        |> Memory.slug_to_title()
      end)
      |> then(&{:ok, &1})
    end
  end

  @impl Memory
  def exists?(title) do
    title
    |> file_path()
    |> File.exists?()
  end

  @impl Memory
  def read(title) do
    path = file_path(title)

    with true <- exists?(title),
         {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    else
      false -> {:error, :not_found}
    end
  end

  @impl Memory
  def save(memory) do
    path = file_path(memory)

    with {:ok, json} <- Memory.marshal(memory),
         {:ok, _result} <- write_file(path, json) do
      :ok
    end
  end

  @impl Memory
  def forget(title) do
    title
    |> file_path()
    |> rm_path()
  end

  @impl Memory
  def is_available?(), do: true

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp storage_path() do
    Store.store_home()
    |> Path.join("memory")
  end

  defp old_storage_path() do
    Store.store_home()
    |> Path.join("memories")
  end

  defp ensure_storage_path() do
    path = storage_path()

    with false <- File.exists?(path),
         :ok <- File.mkdir_p(path) do
      {:ok, path}
    else
      true -> {:ok, path}
    end
  end

  defp drop_old_storage() do
    path = old_storage_path()

    if File.exists?(path) do
      UI.debug("memory:global", "Removing old global memory storage at #{path}")
      File.rm_rf!(path)
    end
  end

  defp file_path(title) when is_binary(title) do
    slug = Memory.title_to_slug(title)
    Path.join(storage_path(), "#{slug}.json")
  end

  defp file_path(%Memory{title: title}) do
    file_path(title)
  end

  defp read_file(path) do
    case FileLock.with_lock(path, fn -> File.read(path) end) do
      {:ok, {:ok, contents}} ->
        {:ok, contents}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_file(path, json) do
    FileLock.with_lock(path, fn -> File.write(path, json) end)
  end

  defp rm_path(path) do
    case FileLock.with_lock(path, fn -> File.rm(path) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:callback_error, reason} -> {:error, reason}
    end
  end
end
