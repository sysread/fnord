defmodule Services.Approvals do
  use GenServer

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  defstruct [:session]

  @type t :: %__MODULE__{session: [Regex.t()]}

  # ----------------------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------------------
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @spec confirm(term, module) ::
          {:ok, :approved}
          | {:denied, binary}
          | {:error, binary}
  def confirm(args, impl) do
    GenServer.call(__MODULE__, {:confirm, impl, args}, :infinity)
  end

  # ----------------------------------------------------------------------------
  # Server API
  # ----------------------------------------------------------------------------
  @impl GenServer
  def init(_) do
    {:ok, %__MODULE__{session: []}}
  end

  @impl GenServer
  def handle_call({:confirm, impl, args}, _from, state) do
    case impl.confirm(state, args) do
      {:approved, new_state} -> {:reply, {:ok, :approved}, new_state}
      {:denied, reason, new_state} -> {:reply, {:denied, reason}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end
end
