defmodule ApprovalsServer do
  @moduledoc """
  Agent-based server for managing command approvals across different scopes.
  
  Manages command approvals in three tiers:
  - Ephemeral: Session-only approvals (not persisted)
  - Project: Project-specific approvals (persisted in Settings)
  - Global: Global approvals for all projects (persisted in Settings)
  
  Uses MapSet union for hierarchical lookup where higher tiers override lower ones.
  Provides promotion paths from ephemeral → project/global → global.
  """

  use Agent

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type state :: %{
          ephemeral: MapSet.t(String.t()),
          project: MapSet.t(String.t()),
          global: MapSet.t(String.t()),
          current_project: String.t() | nil
        }

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  @doc """
  Starts the approvals server with a globally registered name.
  Initializes state by loading persistent approvals from Settings.
  """
  @spec start_link(keyword) :: {:ok, pid} | {:error, term}
  def start_link(_opts \\ []) do
    Agent.start_link(&load_initial_state/0, name: __MODULE__)
  end

  @doc """
  Checks if a command has been approved in any tier (ephemeral, project, or global).
  Uses MapSet union for efficient hierarchical lookup.
  """
  @spec approved?(String.t()) :: boolean
  def approved?(command) do
    Agent.get(__MODULE__, fn state ->
      all_approved = 
        [state.global, state.project, state.ephemeral]
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      MapSet.member?(all_approved, command)
    end)
  end

  @doc """
  Approves a command at the specified scope level.
  
  - `:session` - Session-only approval (ephemeral, not persisted)
  - `:project` - Project-specific approval (persisted to Settings)
  - `:global` - Global approval for all projects (persisted to Settings)
  
  When promoting to a higher tier, the command is removed from lower tiers.
  """
  @spec approve(:session | :project | :global, String.t()) :: :ok | {:error, :no_project}
  def approve(:session, command) do
    Agent.update(__MODULE__, fn state ->
      %{state | ephemeral: MapSet.put(state.ephemeral, command)}
    end)
  end

  def approve(:project, command) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.current_project do
        nil ->
          {{:error, :no_project}, state}

        project_name ->
          # Persist to Settings
          settings = Settings.new()
          Settings.set_command_approval(settings, project_name, command, true)

          # Update state - remove from ephemeral since project overrides
          new_state = %{
            state
            | project: MapSet.put(state.project, command),
              ephemeral: MapSet.delete(state.ephemeral, command)
          }

          {:ok, new_state}
      end
    end)
  end

  def approve(:global, command) do
    Agent.update(__MODULE__, fn state ->
      # Persist to Settings
      settings = Settings.new()
      Settings.set_command_approval(settings, :global, command, true)

      # Update state - remove from lower tiers since global overrides
      %{
        state
        | global: MapSet.put(state.global, command),
          project: MapSet.delete(state.project, command),
          ephemeral: MapSet.delete(state.ephemeral, command)
      }
    end)

    :ok
  end

  @doc """
  Resets the server state to initial loaded state.
  Primarily used for testing.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _state -> load_initial_state() end)
  end

  @doc """
  Returns the current state for debugging/testing purposes.
  """
  @spec get_state() :: state
  def get_state do
    Agent.get(__MODULE__, & &1)
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------

  defp load_initial_state do
    settings = Settings.new()
    current_project = get_current_project()

    # Load global approvals
    global_commands = Settings.get_approved_commands(settings, :global)
    global_approved = 
      global_commands
      |> Enum.filter(fn {_cmd, approved} -> approved end)
      |> Enum.map(fn {cmd, _approved} -> cmd end)
      |> MapSet.new()

    # Load project approvals if project is set
    project_approved = 
      case current_project do
        nil -> 
          MapSet.new()
        
        project_name ->
          project_commands = Settings.get_approved_commands(settings, project_name)
          project_commands
          |> Enum.filter(fn {_cmd, approved} -> approved end)
          |> Enum.map(fn {cmd, _approved} -> cmd end)
          |> MapSet.new()
      end

    %{
      ephemeral: MapSet.new(),
      project: project_approved,
      global: global_approved,
      current_project: current_project
    }
  end

  defp get_current_project do
    case Settings.get_selected_project() do
      {:ok, project_name} -> project_name
      {:error, :project_not_set} -> nil
    end
  end
end