defmodule Util do
  @type async_item ::
          {:ok, any()}
          | {:error, any()}
          # when :zip_input_on_exit is true
          | {:error, {any(), any()}}

  @type async_cb :: (async_item -> any())

  @doc """
  Convenience wrapper for `Services.Globals.Spawn.async_stream/3` with timeout
  defaulting to `:infinity`. Concurrency defaults to `System.schedulers_online()`
  (the `Task.async_stream` default) unless overridden via `max_concurrency`.
  """
  @spec async_stream(Enumerable.t(), async_cb, Keyword.t()) :: Enumerable.t()
  def async_stream(enumerable, fun, options \\ []) do
    opts =
      [
        timeout: :infinity,
        zip_input_on_exit: true
      ]
      |> Keyword.merge(options)

    Services.Globals.Spawn.async_stream(enumerable, fun, opts)
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
    case Http.get("https://hex.pm/api/packages/fnord") do
      {:ok, body} ->
        body
        |> Jason.decode()
        |> case do
          {:ok, %{"latest_version" => version}} -> {:ok, version}
          _ -> :error
        end

      {:http_error, {code, body}} ->
        UI.debug("Hex API request error", "HTTP #{code}: #{body}")
        {:error, :api_request_failed}

      {:transport_error, :nxdomain} ->
        UI.debug("Hex API request error", "No internet connection")
        {:error, :no_internet_connection}

      {:transport_error, reason} ->
        UI.debug("Hex API request error", reason)
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
      do_resolve_symlink(path, root)
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

  @spec do_resolve_symlink(binary, binary, map | nil) ::
          {:ok, binary}
          | {:error, :circular_symlink}
          | {:error, File.posix()}
  defp do_resolve_symlink(path, root, seen \\ %{}) do
    abs_path = expand_path(path, root)

    if Map.has_key?(seen, abs_path) do
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
              |> do_resolve_symlink(root, Map.put(seen, abs_path, true))

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
    if File.exists?(path) do
      with {:ok, resolved_root} <- resolve_symlink(root),
           {:ok, resolved_path} <- resolve_symlink(path, resolved_root) do
        path_segments = Path.split(resolved_path)
        root_segments = Path.split(resolved_root)
        Enum.take(path_segments, length(root_segments)) == root_segments
      else
        _ -> false
      end
    else
      path = expand_path(path, root)
      root = expand_path(root)
      String.starts_with?(path, root <> "/")
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

  @doc """
  Capitalizes the first letter of each word in the input string.
  """
  def ucfirst(input) when is_binary(input) do
    input
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc """
  Adds line numbers to each line of the input text, separated by a specified
  separator (default is "|"). The numbering starts from 1, or `start_index`, if
  set.
  """
  @spec numbered_lines(binary, binary, integer) :: binary
  def numbered_lines(text, separator \\ "|", start_index \\ 1) do
    text
    |> String.split("\n", trim: false)
    |> Enum.with_index(start_index)
    |> Enum.map(fn {line, idx} -> "#{idx}#{separator}#{line}" end)
    |> Enum.join("\n")
  end

  @doc """
  Parses a binary string into an integer, returning `{:ok, int}` if successful,
  or `{:error, :invalid_integer}` if the string cannot be parsed as an integer.
  Accepts both binary strings and integers.
  """
  @spec parse_int(binary | integer) :: {:ok, integer} | {:error, :invalid_integer}
  def parse_int(val) do
    cond do
      is_integer(val) ->
        {:ok, val}

      is_binary(val) ->
        case Integer.parse(val) do
          {int, ""} -> {:ok, int}
          _ -> {:error, :invalid_integer}
        end

      true ->
        {:error, :invalid_integer}
    end
  end

  @doc """
  Converts a value to an integer, raising an `ArgumentError` if the value
  cannot be parsed as an integer. Accepts both binary strings and integers.
  """
  @spec int_damnit(binary | integer) :: integer
  def int_damnit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> raise ArgumentError, "Expected an integer, got: #{value}"
    end
  end

  def int_damnit(value) when is_integer(value), do: value

  def int_damnit(value) do
    raise ArgumentError, "Expected an integer, got: #{inspect(value)}"
  end

  @doc """
  Compares two files using the `diff` command and returns the output.
  If the files are identical, it returns `{:ok, "No changes detected."}`.
  If there are differences, it returns `{:ok, output}` with the diff output.
  If an error occurs, it returns `{:error, output}` with the error message.
  """
  @spec diff_files(binary, binary) :: {:ok, binary} | {:error, binary}
  def diff_files(a, b) do
    System.cmd("diff", ["-u", a, b])
    |> case do
      {_, 0} -> {:ok, "No changes detected."}
      {output, 1} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  @default_limit 50

  defp fallback_limit(n) when is_integer(n) and n > 0, do: n
  defp fallback_limit(_), do: @default_limit

  defp determine_line_limit(max_lines) do
    Util.Env.get_env("FNORD_LOGGER_LINES")
    |> case do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> fallback_limit(max_lines)
        end

      _ ->
        fallback_limit(max_lines)
    end
  end

  defp build_omission(remaining) when remaining > 0 do
    UI.italicize("...plus #{remaining} additional lines")
  end

  defp do_truncate(lines, limit) do
    if length(lines) <= limit do
      Enum.join(lines, "\n")
    else
      {first, rest} = Enum.split(lines, limit)
      (first ++ [build_omission(length(rest))]) |> Enum.join("\n")
    end
  end

  @doc """
  Truncates the input string to a maximum number of lines. If the input has
  more lines than `max_lines`, it keeps the first `max_lines` lines and appends
  a message indicating how many additional lines were omitted. If the input has
  `max_lines` or fewer lines, it returns the input unchanged.
  """
  @spec truncate(binary, non_neg_integer) :: binary
  def truncate(input, max_lines) do
    limit = determine_line_limit(max_lines)
    lines = String.split(input, ~r/\r\n|\n/, trim: false)
    do_truncate(lines, limit)
  end

  @doc """
  Truncates the input string to a maximum number of characters. If the input
  exceeds `max_chars`, it truncates the string and appends an ellipsis ("...").
  If the input is within the limit, it returns the input unchanged.
  """
  @spec truncate_chars(binary, non_neg_integer) :: binary
  def truncate_chars(input, max_chars)
      when is_binary(input) and
             is_integer(max_chars) and
             max_chars > 0 do
    if String.length(input) > max_chars do
      String.slice(input, 0, max_chars) <> "..."
    else
      input
    end
  end

  def truncate_chars(input) when is_binary(input) do
    max_chars = Owl.IO.columns() || 120
    truncate_chars(input, max_chars)
  end
end
