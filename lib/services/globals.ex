defmodule Services.Globals do
  use GenServer

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def set(key, value) do
    GenServer.call(__MODULE__, {:set, key, value})
  end

  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  # ----------------------------------------------------------------------------
  # Project name
  # ----------------------------------------------------------------------------
  def set_project_name(project) do
    set(:project_name, project)
    UI.debug("Project selected", project)
    Services.Notes.load_notes()
  end

  def project_name_is_set?() do
    !is_nil(get(:project_name))
  end

  def get_project_name() do
    get(:project_name)
  end

  # ----------------------------------------------------------------------------
  # Quiet mode
  # ----------------------------------------------------------------------------
  def set_quiet_mode(quiet_mode) do
    set(:quiet_mode, !!quiet_mode)
  end

  def get_quiet_mode() do
    get(:quiet_mode) || false
  end

  # ----------------------------------------------------------------------------
  # Workers
  # ----------------------------------------------------------------------------
  def set_workers(workers) do
    set(:workers, workers)
  end

  def get_workers() do
    get(:workers)
  end

  # ----------------------------------------------------------------------------
  # Edit mode
  # ----------------------------------------------------------------------------
  def set_edit_mode(edit_mode) do
    set(:edit_mode, !!edit_mode)
  end

  def get_edit_mode() do
    get(:edit_mode) || false
  end

  # ----------------------------------------------------------------------------
  # Auto-approve mode
  # ----------------------------------------------------------------------------
  def set_auto_approve(auto_approve) do
    set(:auto_approve, !!auto_approve)
  end

  def get_auto_approve() do
    get(:auto_approve) || false
  end

  # ----------------------------------------------------------------------------
  # Auto-approve policy
  # ----------------------------------------------------------------------------
  @doc """
  Set auto-approval policy for the application. This setting controls how
  unattended approvals are handled.

  The `policy` is a tuple consisting of an action and a timeout (or `nil` to
  disable):
  - `:approve` to automatically approve changes after a timeout.
  - `:deny` to automatically deny changes after a timeout.
  - `nil` to disable auto-approval.

  The `timeout` is specified in milliseconds and determines how long to wait
  before applying the auto-approval policy.

  When an approval is required, the system will first send a notification to
  the user after 60 seconds. If the user does not respond within the timeout
  specified by the auto-approval policy, the specified action will be taken
  automatically.
  """
  @spec set_auto_approve_policy({:approve | :deny, non_neg_integer} | nil) :: :ok
  def set_auto_approve_policy(policy) do
    case policy do
      {policy, timeout} -> set(:auto_policy, {policy, timeout})
      nil -> set(:auto_policy, nil)
    end
  end

  @spec get_auto_approve_policy() :: {:approve | :deny, non_neg_integer} | nil
  def get_auto_approve_policy() do
    get(:auto_policy)
  end

  # ----------------------------------------------------------------------------
  # Project root override
  # ----------------------------------------------------------------------------
  @spec set_project_root_override(binary | nil) :: :ok
  def set_project_root_override(path) do
    set(:project_root_override, path)
  end

  def get_project_root_override() do
    get(:project_root_override)
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:set, key, value}, _from, state) do
    new_state = Map.put(state, key, value)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    value = Map.get(state, key, nil)
    {:reply, value, state}
  end
end
