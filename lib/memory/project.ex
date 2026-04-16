defmodule Memory.Project do
  @moduledoc """
  Project-level memory storage implementation for the `Memory` behaviour.

  Project memory uses the shared file-backed store in `Memory.FileStore`. This
  module primarily resolves the current project and derives the runtime storage
  paths for that shared store.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour Memory

  @impl Memory
  def init() do
    with {:ok, project} <- get_project() do
      Memory.FileStore.init(store(project))
    end
  end

  @impl Memory
  def list() do
    with {:ok, project} <- get_project() do
      Memory.FileStore.list(store(project))
    end
  end

  @impl Memory
  def exists?(title) do
    with {:ok, project} <- get_project() do
      Memory.FileStore.exists?(store(project), title)
    else
      _reason -> false
    end
  end

  @impl Memory
  def read(title) do
    with {:ok, project} <- get_project() do
      Memory.FileStore.read(store(project), title)
    end
  end

  @impl Memory
  def save(memory) do
    with {:ok, project} <- get_project() do
      Memory.FileStore.save(store(project), memory)
    end
  end

  @impl Memory
  def forget(title) do
    with {:ok, project} <- get_project() do
      Memory.FileStore.forget(store(project), title)
    end
  end

  @impl Memory
  def is_available?() do
    case Store.get_project() do
      {:ok, _project} -> true
      _ -> false
    end
  end

  @doc """
  Returns decoded memories for the current project for integration points that
  need full `Memory.t()` structs.

  Use `list_memories/0` when callers need decoded memory records. Use `list/0`
  for the title-oriented listing required by the `Memory` behaviour.
  """
  @spec list_memories() :: {:ok, [Memory.t()]} | {:error, term()}
  def list_memories() do
    with {:ok, project} <- get_project() do
      Memory.FileStore.list_memories(store(project))
    end
  end

  @doc """
  Saves a memory into the given project without changing the currently selected
  project.

  Accepts either a `%Store.Project{}` struct or a project name binary.
  """
  @spec save_into(Store.Project.t() | binary(), Memory.t()) :: :ok | {:error, term()}
  def save_into(project, memory) do
    with {:ok, project} <- resolve_project(project) do
      Memory.FileStore.save(store(project), memory)
    end
  end

  @doc """
  Returns the project-scoped memory storage directory, or `{:error, ...}`
  when no project is selected. Exposed so callers can build per-memory
  lock paths without importing the internal `store/1` helper.
  """
  @spec storage_path() :: {:ok, String.t()} | {:error, term()}
  def storage_path do
    with {:ok, project} <- get_project() do
      {:ok, Path.join(project.store_path, "memory")}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp get_project() do
    Store.get_project()
  end

  defp resolve_project(%Store.Project{} = project), do: {:ok, project}

  defp resolve_project(project_name) when is_binary(project_name) do
    Store.get_project(project_name)
  end

  defp store(%Store.Project{store_path: store_path}) do
    Memory.FileStore.new(
      storage_path: Path.join(store_path, "memory"),
      old_storage_path: Path.join(store_path, "memories"),
      debug_label: "memory:project"
    )
  end
end
