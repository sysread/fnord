defmodule Store.Memories.Heuristic do
  @moduledoc """
  Handles heuristic.json file operations for memories.
  Contains: pattern_tokens (bag-of-words with frequencies)
  """

  @filename "heuristic.json"

  @doc """
  Reads heuristic.json from a memory directory.
  """
  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(memory_dir) do
    path = Path.join(memory_dir, @filename)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    end
  end

  @doc """
  Writes heuristic.json for a memory using atomic write with FileLock.
  """
  @spec write(AI.Memory.t()) :: :ok | {:error, term}
  def write(memory) do
    memory_dir = get_memory_dir(memory)
    path = Path.join(memory_dir, @filename)

    data = %{
      pattern_tokens: memory.pattern_tokens
    }

    with {:ok, json} <- Jason.encode(data, pretty: true) do
      FileLock.with_lock(path, fn ->
        write_atomic(path, json)
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:ok, result} -> result
        error -> error
      end
    end
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
