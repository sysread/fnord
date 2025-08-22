defmodule Services.Approvals do
  @moduledoc """
  A GenServer that provides approval/confirmation services with different
  modes.

  In edit mode, provides full interactive approval with persistence across
  sessions.

  In read-only mode, only allows pre-approved commands and rejects file
  operations.
  """

  use GenServer

  @type scope :: :session | :project | :global
  @type tag :: String.t()
  @type subject :: String.t()
  @type state :: map

  # ----------------------------------------------------------------------------
  # Behavior definition - implementations must provide these callbacks
  # ----------------------------------------------------------------------------
  @doc """
  Prompt for and handle approval request. Returns approval result and updated state.
  """
  @callback confirm(keyword(), state) ::
              {{:ok, :approved} | {:error, String.t()}, state}

  @doc """
  Check if a tag/subject pair is already approved. Returns boolean and updated state.
  """
  @callback is_approved?(tag, subject, state) ::
              {boolean(), state}

  @doc """
  Store approval for tag/subject at given scope. Returns result and updated state.
  """
  @callback approve(scope(), tag, subject, state) ::
              {{:ok, :approved} | {:error, String.t()}, state}

  @doc """
  Enable automatic approval for tag/subject. Returns result and updated state.
  """
  @callback enable_auto_approval(tag, subject, state) ::
              {{:ok, :approved} | {:error, String.t()}, state}

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------

  @doc """
  Initialize implementation state.
  """
  @callback init() :: state

  # GenServer API
  @doc """
  Start the approvals service GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @doc """
  Request approval for a tag/subject with message and detail.
  """
  def confirm(opts, server \\ __MODULE__) do
    GenServer.call(server, {:confirm, opts}, :infinity)
  end

  @doc """
  Check if a tag/subject pair is already approved.
  """
  def is_approved?(tag, subject, server \\ __MODULE__) do
    GenServer.call(server, {:is_approved?, tag, subject})
  end

  @doc """
  Store approval for tag/subject at the given scope.
  """
  def approve(scope, tag, subject, server \\ __MODULE__) do
    GenServer.call(server, {:approve, scope, tag, subject})
  end

  @doc """
  Enable automatic approval for tag/subject.
  """
  def enable_auto_approval(tag, subject, server \\ __MODULE__) do
    GenServer.call(server, {:enable_auto_approval, tag, subject})
  end

  # GenServer callbacks
  @impl GenServer
  def init(_) do
    # Determine which implementation to use
    impl = get_implementation_module()
    state = impl.init()
    {:ok, %{impl: impl, state: state}}
  end

  # Get the implementation module - configurable for testing
  defp get_implementation_module do
    case Application.get_env(:fnord, :approvals_impl) do
      nil ->
        # Default behavior: choose based on edit mode
        if Settings.get_edit_mode() do
          Services.Approvals.EditMode
        else
          Services.Approvals.ReadOnlyMode
        end

      impl when is_atom(impl) ->
        impl
    end
  end

  # ----------------------------------------------------------------------------
  # Server Callbacks
  # ----------------------------------------------------------------------------
  @impl GenServer
  def handle_call({:confirm, opts}, _from, %{impl: impl, state: state} = server_state) do
    {result, new_state} = impl.confirm(opts, state)
    {:reply, result, %{server_state | state: new_state}}
  end

  @impl GenServer
  def handle_call(
        {:is_approved?, tag, subject},
        _from,
        %{impl: impl, state: state} = server_state
      ) do
    {result, new_state} = impl.is_approved?(tag, subject, state)
    {:reply, result, %{server_state | state: new_state}}
  end

  @impl GenServer
  def handle_call(
        {:approve, scope, tag, subject},
        _from,
        %{impl: impl, state: state} = server_state
      ) do
    {result, new_state} = impl.approve(scope, tag, subject, state)
    {:reply, result, %{server_state | state: new_state}}
  end

  @impl GenServer
  def handle_call(
        {:enable_auto_approval, tag, subject},
        _from,
        %{impl: impl, state: state} = server_state
      ) do
    {result, new_state} = impl.enable_auto_approval(tag, subject, state)
    {:reply, result, %{server_state | state: new_state}}
  end
end
