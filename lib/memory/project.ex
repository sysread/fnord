defmodule Memory.Project do
  @moduledoc """
  Project-level memory storage implementation for the `Memory` behaviour.
  Memories are stored as JSON files in `~/.fnord/projects/<project>/memory`.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour Memory

  @impl Memory
  def init() do
    with {:ok, project} <- get_project(),
         {:ok, _path} <- ensure_storage_path(project) do
      drop_old_storage(project)
      :ok
    end
  end

  @impl Memory
  def list() do
    with {:ok, project} <- get_project(),
         {:ok, files} <- project |> storage_path() |> File.ls() do
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
    with {:ok, project} <- get_project() do
      title
      |> file_path(project)
      |> File.exists?()
    else
      _ -> false
    end
  end

  @impl Memory
  def read(title) do
    with {:ok, project} <- get_project(),
         path = file_path(title, project),
         true <- exists?(title),
         {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    else
      false -> {:error, :not_found}
    end
  end

  @impl Memory
  def save(%{title: title} = memory) do
    with {:ok, project} <- get_project(),
         path = file_path(title, project),
         {:ok, json} <- Memory.marshal(memory),
         {:ok, _result} <- write_file(path, json) do
      :ok
    end
  end

  @impl Memory
  def forget(title) do
    with {:ok, project} <- get_project() do
      title
      |> file_path(project)
      |> rm_path()
    end
  end

  @impl Memory
  def is_available?() do
    case Store.get_project() do
      {:ok, _project} -> true
      _ -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp get_project() do
    Store.get_project()
  end

  defp storage_path(%Store.Project{store_path: store_path}) do
    Path.join(store_path, "memory")
  end

  defp old_storage_path(%Store.Project{store_path: store_path}) do
    Path.join(store_path, "memories")
  end

  defp ensure_storage_path(project) do
    path = storage_path(project)

    with false <- File.exists?(path),
         :ok <- File.mkdir_p(path) do
      {:ok, path}
    else
      true -> {:ok, path}
    end
  end

  defp drop_old_storage(project) do
    path = old_storage_path(project)

    if File.exists?(path) do
      UI.debug("memory:project", "Removing old project memory storage at #{path}")
      File.rm_rf!(path)
    end
  end

  defp file_path(title, project) when is_binary(title) do
    slug = Memory.title_to_slug(title)

    project
    |> storage_path()
    |> Path.join("#{slug}.json")
  end

  defp file_path(%Memory{title: title}, project) do
    file_path(title, project)
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
    case FileLock.with_lock(path, fn -> File.write(path, json) end) do
      {:ok, :ok} ->
        {:ok, :ok}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rm_path(path) do
    case FileLock.with_lock(path, fn -> File.rm(path) end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      {:callback_error, reason} ->
        {:error, reason}
    end
  end
end
