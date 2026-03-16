defmodule Memory.FileStore do
  @moduledoc """
  Shared file-backed storage for long-term memories.

  This module underpins both global and project memory stores, preserving
  compatibility with existing file-backed memory layouts while centralizing
  shared lookup, allocation, listing, locking, and JSON marshalling behavior.
  """

  @type t :: %__MODULE__{
          storage_path: String.t(),
          old_storage_path: String.t(),
          debug_label: String.t()
        }

  defstruct [:storage_path, :old_storage_path, :debug_label]

  @doc """
  Ensures the configured storage path exists and removes the retired legacy
  directory when present.
  """
  @spec init(t()) :: :ok | {:error, term()}
  def init(%__MODULE__{} = store) do
    with {:ok, _path} <- ensure_storage_path(store) do
      drop_old_storage(store)
      :ok
    end
  end

  @doc """
  Returns all memory titles by reading each stored file once.
  """
  @spec list(t()) :: {:ok, list(String.t())} | {:error, term()}
  def list(%__MODULE__{} = store) do
    with {:ok, memories} <- list_memories(store) do
      titles =
        memories
        |> Enum.map(& &1.title)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, titles}
    end
  end

  @doc """
  Returns all decodable memories in a single filesystem pass.
  """
  @spec list_memories(t()) :: {:ok, list(Memory.t())} | {:error, term()}
  def list_memories(%__MODULE__{} = store) do
    with {:ok, files} <- File.ls(store.storage_path) do
      memories =
        files
        |> json_files()
        |> Enum.map(&Path.join(store.storage_path, &1))
        |> Enum.reduce([], fn path, acc ->
          case read_memory_file(path) do
            {:ok, memory} -> [memory | acc]
            {:error, _reason} -> acc
          end
        end)
        |> Enum.sort_by(& &1.title)

      {:ok, memories}
    end
  end

  @doc """
  Returns whether a memory with the given title is present.
  """
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = store, title) do
    case find_file_path_by_title(store, title) do
      {:ok, _path} ->
        true

      {:error, _reason} ->
        case base_slug_status(store, title) do
          {:occupied, _path} -> true
          _other -> false
        end
    end
  end

  @doc """
  Reads a memory by title using slug-based lookup with collision fallback.
  """
  @spec read(t(), String.t()) :: {:ok, Memory.t()} | {:error, term()}
  def read(%__MODULE__{} = store, title) do
    with {:ok, path} <- find_file_path_by_title(store, title),
         {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    else
      {:error, :not_found} = err -> err
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Persists a memory, overwriting an existing file for the same title or
  allocating a new collision-safe path when needed.
  """
  @spec save(t(), Memory.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = store, %Memory{title: title} = memory) do
    with {:ok, _path} <- ensure_storage_path(store),
         {:ok, json} <- Memory.marshal(memory) do
      lockfile = Path.join(store.storage_path, ".alloc.lock")

      case FileLock.with_lock(lockfile, fn ->
             path = resolve_save_path(store, title)
             write_file(store, path, json)
           end) do
        {:ok, {:ok, :ok}} -> :ok
        {:ok, {:ok, {:error, reason}}} -> {:error, reason}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp base_slug_status(store, title) do
    slug = Memory.title_to_slug(title)
    path = Path.join(store.storage_path, "#{slug}.json")

    case File.exists?(path) do
      false ->
        :missing

      true ->
        case match_title_in_file(path, title) do
          {:ok, true} -> {:occupied, path}
          {:ok, false} -> :collision
          {:error, _reason} -> {:occupied, path}
        end
    end
  end

  @doc """
  Removes the memory file identified by title.
  """
  @spec forget(t(), String.t()) :: :ok | {:error, term()}
  def forget(%__MODULE__{} = store, title) do
    with {:ok, path} <- find_file_path_by_title(store, title) do
      rm_path(path)
    end
  end

  @doc """
  Builds a store context from runtime paths.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      storage_path: Keyword.fetch!(opts, :storage_path),
      old_storage_path: Keyword.fetch!(opts, :old_storage_path),
      debug_label: Keyword.fetch!(opts, :debug_label)
    }
  end

  @doc """
  Resolves a title to a file path using the canonical slug location first and
  only scanning suffix collisions when the base path does not match.
  """
  @spec find_file_path_by_title(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def find_file_path_by_title(%__MODULE__{} = store, title) do
    slug = Memory.title_to_slug(title)
    base = Path.join(store.storage_path, "#{slug}.json")

    case base_match(base, title) do
      {:ok, path} -> {:ok, path}
      :next -> find_collision_path(store, slug, title)
    end
  end

  defp base_match(path, title) do
    case File.exists?(path) do
      true ->
        case match_title_in_file(path, title) do
          {:ok, true} -> {:ok, path}
          {:ok, false} -> :next
          {:error, _reason} -> normalize_fallback_match(fallback_slug_match(path, title))
        end

      false ->
        :next
    end
  end

  defp find_collision_path(store, slug, title) do
    store
    |> collision_paths(slug)
    |> Enum.find_value({:error, :not_found}, fn path ->
      case match_title_in_file(path, title) do
        {:ok, true} -> {:ok, path}
        {:ok, false} -> false
        {:error, _reason} -> normalize_collision_fallback(fallback_slug_match(path, title))
      end
    end)
  end

  defp fallback_slug_match(path, title) do
    case path_slug_to_title(path) do
      ^title -> {:ok, path}
      _other -> false
    end
  end

  defp normalize_fallback_match({:ok, path}), do: {:ok, path}
  defp normalize_fallback_match(false), do: :next

  defp normalize_collision_fallback({:ok, path}), do: {:ok, path}
  defp normalize_collision_fallback(false), do: false

  defp match_title_in_file(path, title) do
    case read_file(path) do
      {:ok, content} ->
        case Memory.unmarshal(content) do
          {:ok, %Memory{title: ^title}} -> {:ok, true}
          {:ok, %Memory{}} -> {:ok, false}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_save_path(store, title) do
    case find_file_path_by_title(store, title) do
      {:ok, existing_path} -> existing_path
      {:error, :not_found} -> allocate_unique_path_for_title(store, title)
    end
  end

  defp allocate_unique_path_for_title(store, title) do
    slug = Memory.title_to_slug(title)

    case base_slug_status(store, title) do
      :missing ->
        Path.join(store.storage_path, "#{slug}.json")

      {:occupied, path} ->
        case match_title_in_file(path, title) do
          {:ok, true} ->
            path

          {:ok, false} ->
            generate_suffixed_path(store.storage_path, slug, next_suffix_index(store, slug))

          {:error, _reason} ->
            generate_suffixed_path(store.storage_path, slug, next_suffix_index(store, slug))
        end

      :collision ->
        generate_suffixed_path(store.storage_path, slug, next_suffix_index(store, slug))
    end
  end

  defp next_suffix_index(store, slug) do
    store
    |> collision_paths(slug)
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.map(&collision_suffix_index(&1, slug))
    |> Enum.filter(&is_integer/1)
    |> Enum.filter(&(&1 > 0))
    |> case do
      [] -> 1
      numbers -> Enum.max(numbers) + 1
    end
  end

  defp collision_paths(store, slug) do
    [
      collision_pattern(store.storage_path, slug),
      legacy_collision_pattern(store.storage_path, slug)
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp collision_pattern(storage_path, slug) do
    Path.join(storage_path, "#{slug}-*.json")
  end

  defp legacy_collision_pattern(storage_path, slug) do
    Path.join(storage_path, "#{slug}_*.json")
  end

  defp collision_suffix_index(filename, slug) do
    cond do
      String.starts_with?(filename, "#{slug}-") ->
        filename
        |> String.replace_prefix("#{slug}-", "")
        |> Integer.parse()
        |> parse_collision_index()

      String.starts_with?(filename, "#{slug}_") ->
        filename
        |> String.replace_prefix("#{slug}_", "")
        |> Integer.parse()
        |> parse_collision_index()

      true ->
        nil
    end
  end

  defp parse_collision_index({number, ""}), do: number
  defp parse_collision_index({_number, _rest}), do: nil
  defp parse_collision_index(:error), do: nil

  defp path_slug_to_title(path) do
    path
    |> Path.rootname()
    |> Path.basename()
    |> String.replace(~r/[-_]\d+$/, "")
    |> Memory.slug_to_title()
  end

  defp generate_suffixed_path(storage_path, slug, index) do
    Path.join(storage_path, "#{slug}-#{index}.json")
  end

  defp json_files(files) do
    Enum.filter(files, &String.ends_with?(&1, ".json"))
  end

  defp ensure_storage_path(store) do
    path = store.storage_path

    with false <- File.exists?(path),
         :ok <- File.mkdir_p(path) do
      {:ok, path}
    else
      true -> {:ok, path}
    end
  end

  defp drop_old_storage(store) do
    path = store.old_storage_path

    case File.exists?(path) do
      true ->
        UI.debug(store.debug_label, "Removing old memory storage at #{path}")
        File.rm_rf!(path)

      false ->
        :ok
    end
  end

  defp read_memory_file(path) do
    with {:ok, content} <- read_file(path),
         {:ok, memory} <- Memory.unmarshal(content) do
      {:ok, memory}
    end
  end

  defp read_file(path) do
    case FileLock.with_lock(path, fn -> File.read(path) end) do
      {:ok, {:ok, contents}} -> {:ok, contents}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_file(store, path, json) do
    log_write(store, path, json)

    case FileLock.with_lock(path, fn -> File.write(path, json) end) do
      {:ok, :ok} -> {:ok, :ok}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_write(store, path, json) do
    case Util.Env.looks_truthy?("FNORD_DEBUG_MEMORY") do
      true ->
        UI.debug(
          "#{store.debug_label}.write",
          "writing memory to #{path} (#{byte_size(json)} bytes)"
        )

      false ->
        :ok
    end
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
