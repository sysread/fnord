defmodule Services.TempFile do
  @moduledoc """
  Singleton service for creating temporary files via Briefly.

  This centralizes ownership of Briefly-created temp files to a single
  long-lived process, so that files can survive across multiple tool calls
  within the same BEAM node. All options are passed through to
  `Briefly.create/1` unchanged, allowing future callers to migrate without
  changing their option shapes.
  """

  use GenServer

  @type opts :: Keyword.t()

  @spec start_link(any) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, %{}}
  end

  @doc """
  Create a new temporary file via Briefly.

  Accepts an optional keyword list of options and forwards them unchanged
  to `Briefly.create/1`.
  """
  @spec mktemp(opts) :: {:ok, Path.t()} | {:error, term()}
  def mktemp(opts \\ []) do
    GenServer.call(__MODULE__, {:mktemp, opts})
  end

  @doc """
  Like `mktemp/1`, but raises on error.
  """
  @spec mktemp!(opts) :: Path.t()
  def mktemp!(opts \\ []) do
    case mktemp(opts) do
      {:ok, path} -> path
      {:error, reason} -> raise "Services.TempFile.mktemp! failed: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_call({:mktemp, opts}, _from, state) do
    reply =
      case Briefly.create(opts) do
        {:ok, path} -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end
end
