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
      titles =
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          path = Path.join(storage_path(), file)

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
    slug = Memory.title_to_slug(title)
    storage = storage_path()
    base = Path.join(storage, "#{slug}.json")

    # If the base file exists, attempt to read and unmarshal it. If the file
    # is unreadable or contains invalid memory data, we treat the slug as taken
    # (conservative duplicate detection). If it contains a memory with the same
    # title, it's a duplicate. Otherwise, we continue to check suffixed files.
    if File.exists?(base) do
      case File.read(base) do
        {:ok, contents} ->
          case Memory.unmarshal(contents) do
            {:ok, mem} when is_map(mem) and mem.title == title ->
              true

            {:ok, _mem} ->
              # Base file contains a different title; check suffixed files
              wildcard_check(storage, slug, title)

            {:error, _} ->
              # Unreadable/invalid JSON — treat as occupied
              true
          end

        {:error, _} ->
          # Can't read the file; treat as occupied
          true
      end
    else
      wildcard_check(storage, slug, title)
    end
  end

  @impl Memory
  def read(title) do
    with {:ok, path} <- find_file_path_by_title(title),
         {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    else
      {:error, :not_found} = err -> err
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Memory
  def save(%Memory{title: title} = memory) do
    with {:ok, _} <- ensure_storage_path(),
         {:ok, json} <- Memory.marshal(memory) do
      lockfile = Path.join(storage_path(), ".alloc.lock")

      case FileLock.with_lock(lockfile, fn ->
             path = allocate_unique_path_for_title(title)
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
    with {:ok, path} <- find_file_path_by_title(title) do
      rm_path(path)
    end
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

  # Helper functions for slug disambiguation and title-based lookup

  defp find_file_path_by_title(title) do
    slug = Memory.title_to_slug(title)
    storage = storage_path()
    base = Path.join(storage, "#{slug}.json")

    # Attempt base file
    base_match =
      if File.exists?(base) do
        case File.read(base) do
          {:ok, contents} ->
            case Memory.unmarshal(contents) do
              {:ok, mem} when is_map(mem) and mem.title == title ->
                {:ok, base}

              {:error, _reason} ->
                # Unreadable/invalid JSON — fallback to slug-based title match
                if Memory.slug_to_title(Path.rootname(base)) == title do
                  {:ok, base}
                end

              _ ->
                nil
            end

          {:error, _reason} ->
            # Can't read file — fallback to slug-based title match
            if Memory.slug_to_title(Path.rootname(base)) == title do
              {:ok, base}
            end
        end
      end

    # Return base match if found, else scan suffix files
    if base_match do
      base_match
    else
      # Scan suffix files
      pattern = Path.join(storage, "#{slug}-*.json")

      pattern
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.find_value({:error, :not_found}, fn path ->
        case File.read(path) do
          {:ok, contents} ->
            case Memory.unmarshal(contents) do
              {:ok, mem} when is_map(mem) and mem.title == title ->
                {:ok, path}

              {:error, _reason} ->
                # Unreadable/invalid JSON — fallback to slug-based title match
                if Memory.slug_to_title(Path.rootname(path)) == title do
                  {:ok, path}
                end

              _ ->
                nil
            end

          {:error, _reason} ->
            # Can't read file — fallback to slug-based title match
            if Memory.slug_to_title(Path.rootname(path)) == title do
              {:ok, path}
            end
        end
      end)
    end
  end

  defp allocate_unique_path_for_title(title) do
    storage = storage_path()
    allocate_unique_path_for_title(title, storage)
  end

  defp allocate_unique_path_for_title(title, storage) do
    slug = Memory.title_to_slug(title)
    base = Path.join(storage, "#{slug}.json")

    if not File.exists?(base) do
      base
    else
      case File.read(base) do
        {:ok, contents} ->
          case Memory.unmarshal(contents) do
            {:ok, mem} when is_map(mem) and mem.title == title ->
              # Overwrite the existing base file for the same title (migration/updates)
              base

            _ ->
              # Find next available suffix index
              wildcard = Path.join(storage, "#{slug}-*.json")

              next_index =
                wildcard
                |> Path.wildcard()
                |> Enum.map(&Path.basename(&1, ".json"))
                |> Enum.map(fn name -> String.replace_prefix(name, "#{slug}-", "") end)
                |> Enum.filter(&(&1 != ""))
                |> Enum.map(fn s ->
                  case Integer.parse(s) do
                    {i, _} -> i
                    :error -> 0
                  end
                end)
                |> Enum.filter(&(&1 > 0))
                |> case do
                  [] -> 1
                  numbers -> Enum.max(numbers) + 1
                end

              generate_suffixed_path(storage, slug, next_index)
          end

        {:error, _} ->
          # Can't read existing base file; overwrite it
          base
      end
    end
  end

  defp generate_suffixed_path(storage, slug, index) do
    Path.join(storage, "#{slug}-#{index}.json")
  end

  defp wildcard_check(storage, slug, title) do
    pattern = Path.join(storage, "#{slug}-*.json")

    Path.wildcard(pattern)
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, contents} ->
          case Memory.unmarshal(contents) do
            {:ok, mem} when is_map(mem) and mem.title == title -> true
            _ -> false
          end

        {:error, _} ->
          false
      end
    end)
  end
end
