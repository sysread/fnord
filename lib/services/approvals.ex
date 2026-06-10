defmodule Services.Approvals do
  use GenServer

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  defstruct [:session]

  @type t :: %__MODULE__{
          session: [any]
        }

  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @default_impl %{
    edit: Services.Approvals.Edit,
    shell: Services.Approvals.Shell
  }

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  def start_link(_opts \\ []) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, nil) do
      Services.Instance.register(__MODULE__, pid)
      {:ok, pid}
    end
  end

  @spec confirm(term, atom) ::
          {:ok, :approved}
          | {:denied, binary}
          | {:error, binary}
  def confirm(args, kind) do
    Services.Instance.call(__MODULE__, {:confirm, kind, args}, :infinity)
  end

  # ----------------------------------------------------------------------------
  # Server API
  # ----------------------------------------------------------------------------
  @impl GenServer
  def init(_) do
    {:ok, %__MODULE__{session: []}}
  end

  @impl GenServer
  def handle_call({:confirm, kind, args}, _from, state) do
    impl = impl_for(kind)

    # Execute the confirmation in a UI.Queue context to avoid deadlocks
    result =
      UI.Queue.run_from_genserver(fn ->
        impl.confirm(state, args)
      end)

    case result do
      {:approved, new_state} -> {:reply, {:ok, :approved}, new_state}
      {:denied, reason, new_state} -> {:reply, {:denied, reason}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp impl_for(kind) do
    Services.Globals.get_env(:fnord, :approvals, @default_impl)
    |> Map.fetch!(kind)
  end
end
