defmodule Util do
  @type async_item ::
          {:ok, any()}
          | {:error, any()}
          # when :zip_input_on_exit is true
          | {:error, {any(), any()}}

  @type async_cb :: (async_item -> any())

  @doc """
  Convenience wrapper for `Task.async_stream/3` with the default options for
  concurrency and timeout set to `Application.get_env(:fnord, :workers)` and
  `:infinity`, respectively.
  """
  @spec async_stream(Enumerable.t(), async_cb, Keyword.t()) :: Enumerable.t()
  def async_stream(enumerable, fun, options \\ []) do
    opts =
      [
        timeout: :infinity,
        zip_input_on_exit: true
      ]
      |> Keyword.merge(options)

    Task.async_stream(enumerable, fun, opts)
  end

  @doc """
  Filters an enumerable asynchronously using the provided function. The
  function should return `true` for items to keep and `false` for items to
  discard. The result is a stream of items that passed the filter.
  """
  def async_filter(enumerable, fun) do
    enumerable
    |> async_stream(fn item ->
      if fun.(item) do
        item
      else
        :skip
      end
    end)
    |> Stream.filter(fn
      {:ok, :skip} -> false
      {:ok, _} -> true
      _ -> false
    end)
    |> Stream.map(fn {:ok, item} -> item end)
  end

  @doc """
  Converts all string keys in a map to atoms, recursively.
  """
  def string_keys_to_atoms(list) when is_list(list) do
    list |> Enum.map(&string_keys_to_atoms/1)
  end

  def string_keys_to_atoms(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      converted_key =
        if is_binary(key) do
          String.to_atom(key)
        else
          key
        end

      converted_value =
        cond do
          is_map(value) -> string_keys_to_atoms(value)
          is_list(value) -> string_keys_to_atoms(value)
          true -> value
        end

      {converted_key, converted_value}
    end)
    |> Enum.into(%{})
  end

  def string_keys_to_atoms(value), do: value

  def get_running_version do
    {:ok, vsn} = :application.get_key(:fnord, :vsn)
    to_string(vsn)
  end

  def get_latest_version do
    case HTTPoison.get("https://hex.pm/api/packages/fnord", [], follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        body
        |> Jason.decode()
        |> case do
          {:ok, %{"latest_version" => version}} -> {:ok, version}
          _ -> :error
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        IO.warn("Hex API request failed with status #{code}")
        {:error, :api_request_failed}

      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.warn("Hex API request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def format_number(int) when is_integer(int) do
    int
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/\d{3}(?=\d)/, "\\0,")
    |> String.reverse()
  end

  @doc """
  Expands a given path to its absolute form, expanding `.` and `..`. If a root
  directory is provided, it will expand the path relative to that root. If no
  root is provided, it will expand the path relative to the current working
  directory. The root directory is expanded first, if provided (see
  `Path.expand/2`).
  """
  def expand_path(path, root \\ nil) do
    if is_nil(root) do
      Path.expand(path)
    else
      Path.expand(path, root)
    end
  end

  @doc """
  Resolves a symlink to its final target. If the path is relative, it will
  first be expanded relative to the given root. If root is not provided, it
  will expand relative to the current working directory. If a circular symlink
  is detected, it returns `{:error, :circular_symlink}`. Otherwise, it returns
  the absolute, resolved path or the error tuple originating from
  `File.lstat/1`.
  """
  @spec resolve_symlink(binary, binary | nil) ::
          {:ok, binary}
          | {:error, :circular_symlink}
          | {:error, File.posix()}
  def resolve_symlink(path, root \\ nil) do
    with {:ok, root} <- get_root_or_cwd(root) do
      do_resolve_symlink(path, root, MapSet.new())
    end
  end

  @spec get_root_or_cwd(binary | nil) ::
          {:ok, binary}
          | {:error, :enoent}
          | {:error, File.posix()}
  defp get_root_or_cwd(root) do
    if is_nil(root) do
      File.cwd()
    else
      {:ok, root}
    end
  end

  @spec do_resolve_symlink(binary, binary, MapSet.t()) ::
          {:ok, binary}
          | {:error, :circular_symlink}
          | {:error, File.posix()}
  defp do_resolve_symlink(path, root, seen) do
    abs_path = expand_path(path, root)

    if MapSet.member?(seen, abs_path) do
      {:error, :circular_symlink}
    else
      case File.lstat(abs_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(abs_path) do
            {:ok, target} ->
              target
              # target can be relative to the symlink's dir
              |> Path.expand(Path.dirname(abs_path))
              # follow the symlink, but update the memo to prevent circular
              # references from causing infinite recursion
              |> do_resolve_symlink(root, MapSet.put(seen, abs_path))

            error ->
              error
          end

        {:ok, _} ->
          {:ok, abs_path}

        error ->
          error
      end
    end
  end

  @doc """
  Returns `true` if the given path is within the specified root directory,
  `false` otherwise. Expands both the path and the root to their absolute
  forms, resolving symlinks, before performing the check.
  """
  @spec path_within_root?(binary, binary) :: boolean
  def path_within_root?(path, root) do
    with {:ok, resolved_root} <- resolve_symlink(root),
         {:ok, resolved_path} <- resolve_symlink(path, resolved_root) do
      path_segments = Path.split(resolved_path)
      root_segments = Path.split(resolved_root)
      Enum.take(path_segments, length(root_segments)) == root_segments
    else
      _ -> false
    end
  end

  @doc """
  Finds a file within the specified root directory. It resolves symlinks for
  both the file path and the root directory. If the resolved file path is
  within the root directory, it returns `{:ok, resolved_path}`, otherwise
  `{:error, :enoent}`.
  """
  @spec find_file_within_root(binary, binary) :: {:ok, binary} | {:error, :enoent}
  def find_file_within_root(path, root) do
    with {:ok, resolved_path} <- resolve_symlink(path, root),
         true <- Util.path_within_root?(resolved_path, root),
         true <- File.exists?(resolved_path) do
      {:ok, resolved_path}
    else
      _ -> {:error, :enoent}
    end
  end

  @doc """
  Shortcut for `find_file_within_root(path, <cwd>)`. Returns `{:error,
  :enoent}` if the current working directory cannot be determined.
  """
  @spec find_file(binary) :: {:ok, binary} | {:error, :enoent}
  def find_file(path) do
    with {:ok, cwd} <- File.cwd() do
      find_file_within_root(path, cwd)
    else
      _ -> {:error, :enoent}
    end
  end
end
