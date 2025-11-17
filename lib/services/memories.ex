defmodule Services.Memories do
  @moduledoc """
  GenServer maintaining the in-memory graph of all loaded memories.

  Tracks current project context and provides client API for CRUD operations.
  State includes both global and project-scoped memories when a project is selected.
  """

  use GenServer

  defstruct [
    :project_name,
    :memories,
    :by_id,
    :by_slug,
    :roots
  ]

  @type t :: %__MODULE__{
          project_name: String.t() | nil,
          memories: [AI.Memory.t()],
          by_id: %{String.t() => AI.Memory.t()},
          by_slug: %{String.t() => AI.Memory.t()},
          roots: [AI.Memory.t()]
        }

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets all loaded memories (global + project if project selected).
  """
  @spec get_all() :: [AI.Memory.t()]
  def get_all() do
    GenServer.call(__MODULE__, :get_all)
  end

  @doc """
  Gets only root memories (parent_id: nil).
  """
  @spec get_roots() :: [AI.Memory.t()]
  def get_roots() do
    GenServer.call(__MODULE__, :get_roots)
  end

  @doc """
  Gets children of a specific memory by ID.
  """
  @spec get_children(String.t()) :: [AI.Memory.t()]
  def get_children(parent_id) do
    GenServer.call(__MODULE__, {:get_children, parent_id})
  end

  @doc """
  Gets a memory by slug.
  """
  @spec get_by_slug(String.t()) :: AI.Memory.t() | nil
  def get_by_slug(slug) do
    GenServer.call(__MODULE__, {:get_by_slug, slug})
  end

  @doc """
  Gets a memory by ID.
  """
  @spec get_by_id(String.t()) :: AI.Memory.t() | nil
  def get_by_id(id) do
    GenServer.call(__MODULE__, {:get_by_id, id})
  end

  @doc """
  Creates a new memory. Validates parent scope matches if parent_id provided.
  Persists to disk and updates in-memory state.
  """
  @spec create(AI.Memory.t()) :: :ok | {:error, term}
  def create(memory) do
    GenServer.call(__MODULE__, {:create, memory})
  end

  @doc """
  Updates an existing memory. Persists to disk and updates in-memory state.
  """
  @spec update(AI.Memory.t()) :: :ok | {:error, term}
  def update(memory) do
    GenServer.call(__MODULE__, {:update, memory})
  end

  @doc """
  Deletes a memory. Removes from disk and in-memory state.
  """
  @spec delete(String.t()) :: :ok | {:error, term}
  def delete(memory_id) do
    GenServer.call(__MODULE__, {:delete, memory_id})
  end

  @doc """
  Sets the current project context and reloads memories.
  """
  @spec set_project(String.t() | nil) :: :ok
  def set_project(project_name) do
    GenServer.call(__MODULE__, {:set_project, project_name})
  end

  @doc """
  Reloads all memories from disk.
  """
  @spec reload() :: :ok
  def reload() do
    GenServer.call(__MODULE__, :reload)
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Initialize store if needed
    unless Store.Memories.initialized?() do
      Store.Memories.init()
    end

    # Load initial state with no project context
    project_name = get_current_project()
    memories = Store.Memories.load_all(project_name)
    state = build_state(project_name, memories)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_all, _from, state) do
    {:reply, state.memories, state}
  end

  @impl true
  def handle_call(:get_roots, _from, state) do
    {:reply, state.roots, state}
  end

  @impl true
  def handle_call({:get_children, parent_id}, _from, state) do
    case Map.get(state.by_id, parent_id) do
      nil ->
        {:reply, [], state}

      parent ->
        children =
          parent.children
          |> Enum.map(&Map.get(state.by_slug, &1))
          |> Enum.reject(&is_nil/1)

        {:reply, children, state}
    end
  end

  @impl true
  def handle_call({:get_by_slug, slug}, _from, state) do
    {:reply, Map.get(state.by_slug, slug), state}
  end

  @impl true
  def handle_call({:get_by_id, id}, _from, state) do
    {:reply, Map.get(state.by_id, id), state}
  end

  @impl true
  def handle_call({:create, memory}, _from, state) do
    with :ok <- validate_parent_scope(memory, state),
         :ok <- check_slug_collision(memory),
         :ok <- Store.Memories.create(memory) do
      # Add child to parent if parent_id provided
      if memory.parent_id do
        case Map.get(state.by_id, memory.parent_id) do
          nil -> :ok
          parent -> Store.Memories.add_child(parent.slug, memory.slug, parent.scope)
        end
      end

      # Reload to pick up new memory
      memories = Store.Memories.load_all(state.project_name)
      new_state = build_state(state.project_name, memories)
      {:reply, :ok, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update, memory}, _from, state) do
    with :ok <- Store.Memories.Meta.write(memory),
         :ok <- Store.Memories.Heuristic.write(memory) do
      # Reload to pick up changes
      memories = Store.Memories.load_all(state.project_name)
      new_state = build_state(state.project_name, memories)
      {:reply, :ok, new_state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete, memory_id}, _from, state) do
    case Map.get(state.by_id, memory_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      memory ->
        with :ok <- Store.Memories.delete(memory.slug, memory.scope) do
          # Remove from parent's children list if it has a parent
          if memory.parent_id do
            case Map.get(state.by_id, memory.parent_id) do
              nil -> :ok
              parent -> Store.Memories.remove_child(parent.slug, memory.slug, parent.scope)
            end
          end

          # Reload to remove from state
          memories = Store.Memories.load_all(state.project_name)
          new_state = build_state(state.project_name, memories)
          {:reply, :ok, new_state}
        else
          error -> {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:set_project, project_name}, _from, _state) do
    memories = Store.Memories.load_all(project_name)
    new_state = build_state(project_name, memories)

    AI.Memory.debug("Project set to: #{inspect(project_name)}")
    AI.Memory.debug("Loaded #{length(memories)} memories (#{length(new_state.roots)} roots)")

    Enum.each(new_state.roots, fn mem ->
      AI.Memory.debug("  - #{mem.slug} (#{mem.scope})")
    end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    memories = Store.Memories.load_all(state.project_name)
    new_state = build_state(state.project_name, memories)
    {:reply, :ok, new_state}
  end

  # ----------------------------------------------------------------------------
  # Private Helpers
  # ----------------------------------------------------------------------------

  defp get_current_project() do
    case Settings.get_selected_project() do
      {:ok, project} -> project
      {:error, :project_not_set} -> nil
    end
  end

  defp build_state(project_name, memories) do
    by_id = memories |> Enum.map(&{&1.id, &1}) |> Map.new()
    by_slug = memories |> Enum.map(&{&1.slug, &1}) |> Map.new()
    roots = memories |> Enum.filter(&is_nil(&1.parent_id))

    %__MODULE__{
      project_name: project_name,
      memories: memories,
      by_id: by_id,
      by_slug: by_slug,
      roots: roots
    }
  end

  defp validate_parent_scope(memory, state) do
    if memory.parent_id do
      case Map.get(state.by_id, memory.parent_id) do
        nil ->
          {:error, "Parent memory not found: #{memory.parent_id}"}

        parent ->
          if parent.scope == memory.scope do
            :ok
          else
            {:error, "Parent scope (#{parent.scope}) must match child scope (#{memory.scope})"}
          end
      end
    else
      :ok
    end
  end

  defp check_slug_collision(memory) do
    if Store.Memories.exists?(memory.slug, memory.scope) do
      {:error,
       "Memory with label '#{memory.label}' already exists (slug: #{memory.slug}). Choose a more specific label."}
    else
      :ok
    end
  end
end
