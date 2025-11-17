defmodule Store.Memories.Meta do
  @moduledoc """
  Handles meta.json file operations for memories.
  Contains: id, slug, label, response_template, scope, parent_id, timestamps, counters, weight
  """

  @filename "meta.json"

  @doc """
  Reads meta.json from a memory directory.
  Returns {:ok, map} or {:error, reason}.
  """
  @spec read(String.t()) :: {:ok, map} | {:error, term}
  def read(memory_dir) do
    path = Path.join(memory_dir, @filename)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      # Convert string keys to atoms for Memory struct
      {:ok, atomize_keys(data)}
    end
  end

  @doc """
  Writes meta.json for a memory using atomic write.
  """
  @spec write(AI.Memory.t()) :: :ok | {:error, term}
  def write(memory) do
    memory_dir = get_memory_dir(memory)
    path = Path.join(memory_dir, @filename)

    data = %{
      id: memory.id,
      slug: memory.slug,
      label: memory.label,
      response_template: memory.response_template,
      scope: to_string(memory.scope),
      parent_id: memory.parent_id,
      weight: memory.weight,
      created_at: memory.created_at,
      last_fired: memory.last_fired,
      fire_count: memory.fire_count,
      success_count: memory.success_count
    }

    with {:ok, json} <- Jason.encode(data, pretty: true) do
      write_atomic(path, json)
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

  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.new()
    |> then(fn m ->
      # Convert scope string back to atom
      if m[:scope], do: Map.put(m, :scope, String.to_atom(m[:scope])), else: m
    end)
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
