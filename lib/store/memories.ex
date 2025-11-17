defmodule Store.Memories do
  @moduledoc """
  Unix file store for memories with composite scope (global + per-project).

  Directory structure:
    ~/.fnord/memories/           # Global memories
      .metadata.json
      <slug>/
        meta.json
        heuristic.json
        children.log
    ~/.fnord/projects/<project>/memories/  # Project memories
      <slug>/
        ...
  """

  # Base path uses Settings.get_user_home/0 to respect test overrides
  defp base_path(), do: Path.join(Settings.get_user_home(), ".fnord/memories")
  @metadata_file ".metadata.json"

  # ----------------------------------------------------------------------------
  # Initialization
  # ----------------------------------------------------------------------------

  @doc """
  Initializes the memories store directory structure.
  Creates base directory for global memories and root metadata.
  Project memories are created under each project's store directory.
  """
  @spec init() :: :ok | {:error, term}
  def init() do
    with :ok <- File.mkdir_p(base_path()),
         :ok <- init_metadata() do
      :ok
    end
  end

  @doc """
  Checks if the memories store has been initialized.
  """
  @spec initialized?() :: boolean
  def initialized?() do
    File.dir?(base_path()) and File.exists?(metadata_path())
  end

  # ----------------------------------------------------------------------------
  # Loading
  # ----------------------------------------------------------------------------

  @doc """
  Loads all global memories from disk.
  """
  @spec load_global() :: [AI.Memory.t()]
  def load_global() do
    global_path()
    |> load_memories_from_path()
  end

  @doc """
  Loads all memories for a specific project.
  """
  @spec load_project(String.t()) :: [AI.Memory.t()]
  def load_project(project_name) do
    project_path(project_name)
    |> load_memories_from_path()
  end

  @doc """
  Loads all memories: global + project if project_name provided.
  """
  @spec load_all(String.t() | nil) :: [AI.Memory.t()]
  def load_all(nil), do: load_global()

  def load_all(project_name) do
    load_global() ++ load_project(project_name)
  end

  # ----------------------------------------------------------------------------
  # CRUD Operations
  # ----------------------------------------------------------------------------

  @doc """
  Creates a new memory directory and writes initial files.
  """
  @spec create(AI.Memory.t()) :: :ok | {:error, term}
  def create(memory) do
    memory_path = get_memory_path(memory)

    with :ok <- File.mkdir_p(memory_path),
         :ok <- Store.Memories.Meta.write(memory),
         :ok <- Store.Memories.Heuristic.write(memory),
         :ok <- Store.Memories.Children.write(memory, []) do
      :ok
    end
  end

  @doc """
  Checks if a memory exists.
  """
  @spec exists?(String.t(), AI.Memory.scope()) :: boolean
  def exists?(slug, scope) do
    scope_path(scope)
    |> Path.join(slug)
    |> File.dir?()
  end

  @doc """
  Deletes a memory and all its files.
  """
  @spec delete(String.t(), AI.Memory.scope()) :: :ok | {:error, term}
  def delete(slug, scope) do
    scope_path(scope)
    |> Path.join(slug)
    |> File.rm_rf()
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ----------------------------------------------------------------------------
  # Hierarchy Operations
  # ----------------------------------------------------------------------------

  @doc """
  Adds a child slug to a parent's children.log file.
  """
  @spec add_child(String.t(), String.t(), AI.Memory.scope()) :: :ok | {:error, term}
  def add_child(parent_slug, child_slug, scope) do
    parent_path = Path.join(scope_path(scope), parent_slug)
    children = Store.Memories.Children.read(parent_path)

    unless child_slug in children do
      Store.Memories.Children.write_path(parent_path, [child_slug | children])
    else
      :ok
    end
  end

  @doc """
  Removes a child slug from a parent's children.log file.
  """
  @spec remove_child(String.t(), String.t(), AI.Memory.scope()) :: :ok | {:error, term}
  def remove_child(parent_slug, child_slug, scope) do
    parent_path = Path.join(scope_path(scope), parent_slug)
    children = Store.Memories.Children.read(parent_path)
    updated = Enum.reject(children, &(&1 == child_slug))
    Store.Memories.Children.write_path(parent_path, updated)
  end

  @doc """
  Gets all child slugs for a memory.
  """
  @spec get_children(String.t(), AI.Memory.scope()) :: [String.t()]
  def get_children(slug, scope) do
    scope_path(scope)
    |> Path.join(slug)
    |> Store.Memories.Children.read()
  end

  @doc """
  Finds the parent slug for a given child slug.
  Returns nil if no parent found.
  """
  @spec find_parent(String.t(), AI.Memory.scope()) :: String.t() | nil
  def find_parent(child_slug, scope) do
    # Use rg to search children.log files for the child slug
    # Note: rg doesn't expand globs, so we need to expand them first
    pattern = "^#{Regex.escape(child_slug)}$"

    children_logs =
      scope_path(scope)
      |> Path.join("*/children.log")
      |> Path.wildcard()

    if Enum.empty?(children_logs) do
      nil
    else
      case System.cmd("rg", ["-l", pattern | children_logs], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> List.first()
          |> case do
            nil -> nil
            path -> path |> Path.dirname() |> Path.basename()
          end

        _ ->
          nil
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Helpers
  # ----------------------------------------------------------------------------

  defp global_path(), do: base_path()

  defp project_path(name) do
    # Project memories stored in the project's store directory
    Path.join([Settings.get_user_home(), ".fnord/projects", name, "memories"])
  end

  defp metadata_path(), do: Path.join(base_path(), @metadata_file)

  defp scope_path(:global) do
    global_path()
  end

  defp scope_path(:project) do
    case Settings.get_selected_project() do
      {:ok, project_name} ->
        project_path(project_name)

      {:error, :project_not_set} ->
        raise "Cannot access project-scoped memories without a selected project"
    end
  end

  defp get_memory_path(memory) do
    Path.join(scope_path(memory.scope), memory.slug)
  end

  defp init_metadata() do
    metadata = %{
      migrations_applied: [],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Jason.encode(metadata, pretty: true) do
      {:ok, json} ->
        File.write(metadata_path(), json)

      error ->
        error
    end
  end

  defp load_memories_from_path(path) do
    if File.dir?(path) do
      path
      |> Path.join("*/meta.json")
      |> Path.wildcard()
      |> Enum.map(&Path.dirname/1)
      |> Enum.map(&load_memory_from_dir/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp load_memory_from_dir(memory_dir) do
    with {:ok, meta} <- Store.Memories.Meta.read(memory_dir),
         {:ok, heuristic} <- Store.Memories.Heuristic.read(memory_dir),
         children <- Store.Memories.Children.read(memory_dir) do
      AI.Memory.new(
        Map.merge(meta, %{
          pattern_tokens: heuristic["pattern_tokens"] || %{},
          children: children
        })
      )
    else
      _ -> nil
    end
  end
end
