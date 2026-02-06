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
      titles =
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          path = Path.join(storage_path(project), file)

          case read_file(path) do
            {:ok, contents} ->
              case Memory.unmarshal(contents) do
                {:ok, mem} when is_map(mem) and is_binary(mem.title) -> mem.title
                _ -> Memory.slug_to_title(Path.rootname(file))
              end

            {:error, _} ->
              Memory.slug_to_title(Path.rootname(file))
          end
        end)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, titles}
    end
  end

  @impl Memory
  def exists?(title) do
    with {:ok, project} <- get_project(),
         {:ok, _path} <- find_file_path_by_title(title, project) do
      true
    else
      _ -> false
    end
  end

  @impl Memory
  def read(title) do
    with {:ok, project} <- get_project(),
         {:ok, path} <- find_file_path_by_title(title, project),
         {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    else
      error -> error
    end
  end

  @impl Memory
  def save(%{title: title} = memory) do
    with {:ok, project} <- get_project(),
         {:ok, json} <- Memory.marshal(memory) do
      lockfile = Path.join(storage_path(project), ".alloc.lock")

      case FileLock.with_lock(lockfile, fn ->
             {:ok, path} = allocate_unique_path_for_title(title, project)
             write_file(path, json)
           end) do
        {:ok, {:ok, :ok}} -> :ok
        {:ok, {:ok, {:error, reason}}} -> {:error, reason}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Memory
  def forget(title) do
    with {:ok, project} <- get_project(),
         {:ok, path} <- find_file_path_by_title(title, project) do
      rm_path(path)
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

  # Helper functions for title-based lookup and unique path allocation

  defp find_file_path_by_title(title, project) do
    storage = storage_path(project)

    case File.ls(storage) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.find_value({:error, :not_found}, fn file ->
          path = Path.join(storage, file)

          case read_file(path) do
            {:ok, content} ->
              case Memory.unmarshal(content) do
                {:ok, mem} when is_map(mem) and is_binary(mem.title) ->
                  if mem.title == title, do: {:ok, path}, else: false

                _ ->
                  if Memory.slug_to_title(Path.rootname(file)) == title,
                    do: {:ok, path},
                    else: false
              end

            {:error, _reason} ->
              if Memory.slug_to_title(Path.rootname(file)) == title, do: {:ok, path}, else: false
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allocate_unique_path_for_title(title, project) do
    with {:ok, storage} <- ensure_storage_path(project) do
      base = Memory.title_to_slug(title)
      path = Path.join(storage, "#{base}.json")

      if File.exists?(path) do
        generate_suffixed_path(storage, base)
      else
        {:ok, path}
      end
    end
  end

  defp generate_suffixed_path(storage, base, counter \\ 1) do
    name = "#{base}_#{counter}"
    path = Path.join(storage, "#{name}.json")

    if File.exists?(path) do
      generate_suffixed_path(storage, base, counter + 1)
    else
      {:ok, path}
    end
  end
end
