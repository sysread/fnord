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
  def new(path, continue? \\ fn _ -> true end) when is_function(continue?, 1) do
    Stream.resource(
      # Initialize with the root directory
      fn -> [path] end,
      # Fetch the next batch of files/directories
      &next_paths(&1, continue?),
      # Cleanup is a no-op
      fn _ -> :ok end
    )
  end

  defp next_paths([], _continue?), do: {:halt, []}

  defp next_paths([current_path | rest_paths], continue?) do
    case File.ls(current_path) do
      {:ok, entries} ->
        full_paths =
          entries
          |> Enum.map(&Path.join(current_path, &1))
          |> Enum.map(&Path.expand/1)

        # Separate files and directories
        {files, dirs} = Enum.split_with(full_paths, &File.regular?/1)

        # Check whether to continue traversing directories
        dirs_to_traverse =
          Enum.filter(dirs, continue?)

        # Return files as the current chunk and add selected dirs to the queue
        {files, dirs_to_traverse ++ rest_paths}

      {:error, _reason} ->
        # Skip unreadable paths
        next_paths(rest_paths, continue?)
    end
  end
end
