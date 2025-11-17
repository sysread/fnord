defmodule Store.Memories.Children do
  @moduledoc """
  Handles children.log file operations for memories.
  Format: newline-delimited list of child slugs (one per line).
  """

  @filename "children.log"

  @doc """
  Reads children.log from a memory directory.
  Returns list of child slugs.
  """
  @spec read(String.t()) :: [String.t()]
  def read(memory_dir) do
    path = Path.join(memory_dir, @filename)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)

      {:error, :enoent} ->
        []

      {:error, _} ->
        []
    end
  end

  @doc """
  Writes children.log for a memory using atomic write.
  Takes a memory struct.
  """
  @spec write(AI.Memory.t(), [String.t()]) :: :ok | {:error, term}
  def write(memory, children) do
    memory_dir = get_memory_dir(memory)
    write_path(memory_dir, children)
  end

  @doc """
  Writes children.log to a specific path (used by parent operations).
  """
  @spec write_path(String.t(), [String.t()]) :: :ok | {:error, term}
  def write_path(memory_dir, children) do
    path = Path.join(memory_dir, @filename)
    content = Enum.join(children, "\n")

    write_atomic(path, content)
  end

  # ----------------------------------------------------------------------------
  # Private Helpers
  # ----------------------------------------------------------------------------

  defp get_memory_dir(%AI.Memory{scope: :global, slug: slug}) do
    Path.join([Settings.get_user_home(), ".fnord/memories", slug])
  end

  defp get_memory_dir(%AI.Memory{scope: :project, slug: slug}) do
    case Settings.get_selected_project() do
      {:ok, project_name} ->
        Path.join([Settings.get_user_home(), ".fnord/projects", project_name, "memories", slug])

      {:error, :project_not_set} ->
        raise "Cannot save project-scoped memory without a selected project. Use 'fnord config set-project <name>' first."
    end
  end

  defp write_atomic(path, content) do
    dir = Path.dirname(path)
    base = Path.basename(path)
    tmp = Path.join(dir, ".#{base}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end
end
