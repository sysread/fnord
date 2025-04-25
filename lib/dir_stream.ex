defmodule DirStream do
  @doc """
  Creates a stream that lazily traverses the given directory recursively.

  The `continue?` callback allows the caller to control traversal. It is called
  with each directory path before traversing its contents. If it returns
  `false`, the directory is skipped.

  ## Parameters:
    - `path` (String): The root directory to traverse.
    - `continue?` (Function, optional): A function `(String.t() -> boolean)`
      that determines whether to continue traversing a directory.
      Defaults to always continuing.

  ## Returns:
    - A `Stream` that yields file paths.
  """
  def new(path, continue? \\ fn _ -> true end) do
    root = Path.expand(path)

    Stream.resource(
      fn -> [root] end,
      &next_paths(&1, continue?),
      fn _ -> :ok end
    )
  end

  defp next_paths([], _continue?), do: {:halt, []}

  defp next_paths([current | rest_paths], continue?) do
    case File.ls(current) do
      {:ok, entries} ->
        {files, dirs_to_traverse} =
          Enum.reduce(entries, {[], []}, fn entry, {files_acc, dirs_acc} ->
            full = Path.join(current, entry)
            is_dir = File.dir?(full)

            cond do
              is_dir and continue?.(full) -> {files_acc, [full | dirs_acc]}
              is_dir -> {files_acc, dirs_acc}
              true -> {[full | files_acc], dirs_acc}
            end
          end)

        {files, dirs_to_traverse ++ rest_paths}

      {:error, _reason} ->
        next_paths(rest_paths, continue?)
    end
  end
end
