defmodule Services.Approvals do
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
          global: MapSet.t(String.t())
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
    command = to_string(command)
    Agent.get(__MODULE__, fn state ->
      # Load project approvals dynamically based on current project
      current_project_approvals = 
        case get_current_project() do
          nil -> 
            MapSet.new()
          project_name ->
            settings = Settings.new()
            project_commands = Settings.get_approved_commands(settings, project_name)
            project_commands
            |> Enum.filter(fn {_cmd, approved} -> approved end)
            |> Enum.map(fn {cmd, _approved} -> cmd end)
            |> MapSet.new()
        end

      all_approved = 
        [state.global, current_project_approvals, state.ephemeral]
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
    command = to_string(command)
    Agent.update(__MODULE__, fn state ->
      %{state | ephemeral: MapSet.put(state.ephemeral, command)}
    end)
  end

  def approve(:project, command) do
    command = to_string(command)
    Agent.get_and_update(__MODULE__, fn state ->
      # Check current project dynamically instead of relying on cached state
      case get_current_project() do
        nil ->
          {{:error, :no_project}, state}

        project_name ->
          # Persist to Settings - need to use the returned value to ensure it's saved
          settings = Settings.new()
          _updated_settings = Settings.set_command_approval(settings, project_name, command, true)

          # Update state - remove from ephemeral since project overrides
          new_state = %{
            state
            | ephemeral: MapSet.delete(state.ephemeral, command)
          }

          {:ok, new_state}
      end
    end)
  end

  def approve(:global, command) do
    command = to_string(command)
    Agent.update(__MODULE__, fn state ->
      # Persist to Settings - need to use the returned value to ensure it's saved
      settings = Settings.new()
      _updated_settings = Settings.set_command_approval(settings, :global, command, true)

      # Update state - remove from lower tiers since global overrides
      %{
        state
        | global: MapSet.put(state.global, command),
          ephemeral: MapSet.delete(state.ephemeral, command)
      }
    end)
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

    # Load global approvals
    global_commands = Settings.get_approved_commands(settings, :global)
    global_approved = 
      global_commands
      |> Enum.filter(fn {_cmd, approved} -> approved end)
      |> Enum.map(fn {cmd, _approved} -> cmd end)
      |> MapSet.new()

    %{
      ephemeral: MapSet.new(),
      global: global_approved
    }
  end

  defp get_current_project do
    case Settings.get_selected_project() do
      {:ok, project_name} -> project_name
      {:error, :project_not_set} -> nil
    end
  end
end