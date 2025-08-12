defmodule Services.Approvals do
  @moduledoc """
  Agent-based server for managing command approvals across different scopes.

  Manages command approvals in three tiers:
  - Ephemeral: Session-only approvals (not persisted)
  - Project: Project-specific approvals (persisted in Settings)
  - Global: Global approvals for all projects (persisted in Settings)

  Uses MapSet union for hierarchical lookup where higher tiers override lower ones.
  Provides promotion paths from ephemeral → project/global → global.

  ## Command Confirmation Workflow

  The service handles the complete user confirmation workflow for commands
  via `confirm_command/3`. This includes:

  - Pre-approval checking using hierarchical lookup
  - Interactive user prompts with approval scope options
  - Special security handling for complex commands that require per-execution approval
  - Automatic approval storage at the requested scope

  Commands are identified using approval_bits (parsed command components) which
  enable hierarchical approval of command families and subcommands.

  ## Examples

      # Check if a command is approved
      Services.Approvals.approved?("action#git#status")

      # Approve a command for current session
      Services.Approvals.approve(:session, "action#make#build")

      # Full confirmation workflow with custom tag
      Services.Approvals.confirm_command(
        "Build the project",
        ["make", "build"],
        "make build",
        tag: "build_tool"
      )
  """

  use Agent

  @default_tag "action"

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type state :: %{
          ephemeral: MapSet.t(String.t()),
          global: MapSet.t(String.t())
        }

  @typedoc """
  Parsed command components used for approval key generation.
  These represent the command structure that can be approved hierarchically,
  allowing for approval of command families and subcommands.
  """
  @type approval_bits :: [String.t()]

  @typedoc """
  Result of a command confirmation request.
  """
  @type confirmation_result ::
          {:ok, :approved}
          | {:error, String.t()}

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
  Uses hierarchical lookup with the new nested format.
  """
  @spec approved?(String.t()) :: boolean
  def approved?(command) do
    command = to_string(command)

    Agent.get(__MODULE__, fn state ->
      # Check ephemeral first (uses command keys)
      if MapSet.member?(state.ephemeral, command) do
        true
      else
        # Parse command to check persistent storage in new format
        {tag, command_parts} = parse_command_key(command, [])

        # Check project approvals
        project_approved =
          case get_current_project() do
            nil ->
              false

            project_name ->
              settings = Settings.new()
              Settings.is_command_approved?(settings, project_name, tag, command_parts)
          end

        # Check global approvals if not approved at project level
        global_approved =
          if project_approved do
            true
          else
            # Check in-memory global approvals or in persistent storage
            MapSet.member?(state.global, command) or
              Settings.new() |> Settings.is_command_approved?(:global, tag, command_parts)
          end

        project_approved or global_approved
      end
    end)
  end

  @doc """
  Approves a command at the specified scope level.

  - `:session` - Session-only approval (ephemeral, not persisted)
  - `:project` - Project-specific approval (persisted to Settings)
  - `:global` - Global approval for all projects (persisted to Settings)

  When promoting to a higher tier, the command is removed from lower tiers.

  ## Parameters
  - `scope`: The approval scope
  - `command_key`: Either a full "tag#command#parts" key or just the command for session-only approval
  - `opts`: Optional parameters including `:tag` and `:command_parts` to override parsing
  """
  @spec approve(:session | :project | :global, String.t(), keyword()) ::
          :ok | {:error, :no_project}
  def approve(scope, command_key, opts \\ [])

  def approve(:session, command_key, _opts) do
    command_key = to_string(command_key)

    Agent.update(__MODULE__, fn state ->
      %{state | ephemeral: MapSet.put(state.ephemeral, command_key)}
    end)
  end

  def approve(:project, command_key, opts) do
    command_key = to_string(command_key)
    {tag, command_parts} = parse_command_key(command_key, opts)

    Agent.get_and_update(__MODULE__, fn state ->
      case get_current_project() do
        nil ->
          {{:error, :no_project}, state}

        project_name ->
          # Persist using new format
          settings = Settings.new()

          _updated_settings =
            Settings.add_approved_command(settings, project_name, tag, command_parts)

          # Update state - remove from ephemeral since project overrides
          new_state = %{
            state
            | ephemeral: MapSet.delete(state.ephemeral, command_key)
          }

          {:ok, new_state}
      end
    end)
  end

  def approve(:global, command_key, opts) do
    command_key = to_string(command_key)
    {tag, command_parts} = parse_command_key(command_key, opts)

    Agent.update(__MODULE__, fn state ->
      # Persist using new format
      settings = Settings.new()
      _updated_settings = Settings.add_approved_command(settings, :global, tag, command_parts)

      # Update state - remove from lower tiers since global overrides
      %{
        state
        | global: MapSet.put(state.global, command_key),
          ephemeral: MapSet.delete(state.ephemeral, command_key)
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

  @doc """
  Handles the complete command confirmation workflow.

  Checks if the command is already approved, and if not, prompts the user
  for approval with options to approve at different scopes (session, project, global).

  Special handling for complex commands that cannot be approved for persistent
  sessions due to security concerns (detected by command pattern matching).

  ## Parameters
  - `description`: Human-readable explanation of what the command does
  - `approval_bits`: Parsed command components for hierarchical approval
  - `full_command`: Complete command string for display to user
  - `opts`: Options including `:tag` to customize the command key prefix (defaults to "action")

  ## Returns
  - `{:ok, :approved}` if approved
  - `{:error, reason}` if denied or error occurred
  """
  @spec confirm_command(String.t(), approval_bits, String.t(), keyword()) :: confirmation_result
  def confirm_command(description, approval_bits, full_command, opts \\ [])

  def confirm_command(description, approval_bits, full_command, opts) do
    tag = Keyword.get(opts, :tag, @default_tag)
    command_key = build_command_key(approval_bits, tag)

    if approved?(command_key) do
      {:ok, :approved}
    else
      confirm_with_approval_options(description, approval_bits, full_command, command_key, opts)
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------

  defp build_command_key(approval_bits, tag) do
    [tag | approval_bits]
    |> Enum.join("#")
  end

  defp parse_command_key(command_key, opts) do
    case Keyword.get(opts, :tag) do
      nil ->
        # Parse from command_key format "tag#cmd#parts"
        case String.split(command_key, "#", parts: 2) do
          [tag, command_parts] -> {tag, command_parts}
          [single_part] -> {@default_tag, single_part}
        end

      tag ->
        # Use provided tag and command parts
        command_parts = Keyword.get(opts, :command_parts, command_key)
        {tag, command_parts}
    end
  end

  defp confirm_with_approval_options(description, approval_bits, full_command, command_key, opts) do
    persistent = Keyword.get(opts, :persistent, true)

    base_options = [
      "You son of a bitch, I'm in",
      "Deny",
      "Deny (with feedback)"
    ]

    if persistent do
      approval_str = ["You son of a... for the whole session:" | approval_bits] |> Enum.join(" ")

      project_approval_str =
        ["You son of a... for this project:" | approval_bits] |> Enum.join(" ")

      global_approval_str = ["You son of a... globally:" | approval_bits] |> Enum.join(" ")

      options = [
        "You son of a bitch, I'm in",
        approval_str,
        project_approval_str,
        global_approval_str,
        "Deny",
        "Deny (with feedback)"
      ]

      prompt_text = """
      The AI agent would like to execute a command.

      # Command
      ```sh
      #{full_command}
      ```

      # Description and Purpose
      > #{description}

      # Approval
      You can approve this call only, or you can approve all future calls for
      this command and its subcommands for:
      - This session only (not saved)
      - This project (saved persistently in project settings)
      - All projects globally (saved persistently in global settings)
      """

      prompt_text
      |> UI.choose(options)
      |> handle_approval_choice(
        approval_str,
        project_approval_str,
        global_approval_str,
        command_key
      )
    else
      # Non-persistent approval - only immediate approval or deny
      prompt_text = """
      The AI agent would like to execute a command.

      # Command
      ```sh
      #{full_command}
      ```

      # Description and Purpose
      > #{description}

      # Approval
      _Complex commands involving pipes, redirection, command substitution, and
      other advanced features cannot be approved for the entire session. You must
      approve each command individually._
      """

      prompt_text
      |> UI.choose(base_options)
      |> case do
        "Deny (with feedback)" ->
          feedback = UI.prompt("Opine away:")
          {:error, "The user declined to approve the command. They responded with:\n#{feedback}"}

        "Deny" ->
          {:error, "The user declined to approve the command."}

        "You son of a bitch, I'm in" ->
          {:ok, :approved}
      end
    end
  end

  defp handle_approval_choice(
         choice,
         approval_str,
         project_approval_str,
         global_approval_str,
         command_key
       ) do
    case choice do
      "Deny (with feedback)" ->
        feedback = UI.prompt("Opine away:")
        {:error, "The user declined to approve the command. They responded with:\n#{feedback}"}

      "Deny" ->
        {:error, "The user declined to approve the command."}

      "You son of a bitch, I'm in" ->
        {:ok, :approved}

      ^approval_str ->
        approve(:session, command_key)
        {:ok, :approved}

      ^project_approval_str ->
        case approve(:project, command_key) do
          :ok ->
            {:ok, :approved}

          {:error, :no_project} ->
            {:error,
             "Cannot approve for project: no project is currently set. Use 'fnord config set <project>' to set a project first."}
        end

      ^global_approval_str ->
        approve(:global, command_key)
        {:ok, :approved}
    end
  end

  defp load_initial_state do
    settings = Settings.new()

    # Load global approvals from Settings
    global_commands = Settings.get_approved_commands(settings, :global)

    # Convert new format to internal command keys for MapSet storage
    global_approved =
      global_commands
      |> Enum.flat_map(fn
        # New format: {"tag" => ["cmd1", "cmd2"]}
        {tag, command_list} when is_list(command_list) ->
          # Tagged commands - build internal key format
          Enum.map(command_list, &"#{tag}##{&1}")

        _ ->
          []
      end)
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
