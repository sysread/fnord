defmodule Services.ProviderConcurrency do
  @moduledoc """
  Per-provider concurrency cap for `AI.Endpoint.post_json/3`.

  A single Coordinator review run forks into many parallel sub-agents
  (5 scoped reviewers + integration reviewer + 5 specialist
  delegates per reviewer + per-specialist research/file-info agents),
  each making its own HTTP completion. When the active provider has a
  tight per-account budget (Inception's input-token-per-minute, for
  example), the parallel fan-out can saturate the budget instantly and
  every in-flight call ends up burning the retry budget without any
  caller making forward progress.

  This service gates entry to `AI.Endpoint.post_json/3` with a
  per-provider semaphore. Callers acquire a slot before sending, then
  release it after the call (including all retries) completes.
  Excess callers queue and are served FIFO when a slot frees.

  ## Limits

  Configured per-provider via `@limits`. `:infinity` means no cap.
  Current picks:
  - openai: `:infinity` (no observed throttling under fan-out)
  - venice: 3 (some models get throttle-prone above this)
  - deepseek: 3 (start conservative; raise once we have data)

  Bumping limits is a one-line change in this module. If a future
  provider needs different semantics (per-model, per-key, ...) extend
  the key shape rather than rewriting the protocol.

  ## Fail-open

  If the GenServer isn't running (tests, unsupervised startup,
  whatever), `with_slot/2` falls through to running the function
  directly without gating. The cap is a smoothing mechanism, not a
  correctness gate - failing closed would create harder-to-debug
  hangs than just letting parallel calls fly during test runs.
  """

  use GenServer

  @name __MODULE__

  @limits %{
    "openai" => :infinity,
    "venice" => 3,
    "deepseek" => 3
  }

  defstruct counts: %{}, waiters: %{}

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  @doc "Start the concurrency service."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  Run `fun` while holding a concurrency slot for the active provider.

  Blocks until a slot is available. The slot is released when `fun`
  returns, whether normally or via raise/throw/exit. Fail-open: if
  the service isn't running, runs `fun` immediately without gating.
  """
  @spec with_slot(String.t(), (-> any())) :: any()
  def with_slot(provider, fun) when is_function(fun, 0) do
    case acquire(provider) do
      :ok ->
        try do
          fun.()
        after
          release(provider)
        end

      :fail_open ->
        fun.()
    end
  end

  @doc "Return the configured limit map (for diagnostics / tests)."
  @spec limits() :: %{String.t() => non_neg_integer | :infinity}
  def limits, do: @limits

  # ----------------------------------------------------------------------------
  # Internal acquire/release
  # ----------------------------------------------------------------------------

  defp acquire(provider) do
    case Process.whereis(@name) do
      nil -> :fail_open
      _pid -> GenServer.call(@name, {:acquire, provider}, :infinity)
    end
  end

  defp release(provider) do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.cast(@name, {:release, provider})
    end
  end

  # ----------------------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------------------

  @impl GenServer
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:acquire, provider}, from, %__MODULE__{} = state) do
    case limit_for(provider) do
      :infinity ->
        # No cap - reply immediately without bumping counters.
        {:reply, :ok, state}

      limit ->
        current = Map.get(state.counts, provider, 0)

        if current < limit do
          {:reply, :ok, %{state | counts: Map.put(state.counts, provider, current + 1)}}
        else
          q = Map.get(state.waiters, provider, :queue.new())
          {:noreply, %{state | waiters: Map.put(state.waiters, provider, :queue.in(from, q))}}
        end
    end
  end

  @impl GenServer
  def handle_cast({:release, provider}, %__MODULE__{} = state) do
    q = Map.get(state.waiters, provider, :queue.new())

    case :queue.out(q) do
      {{:value, waiter}, rest} ->
        # Hand the slot directly to the next waiter without
        # decrementing - the new owner takes the count we were
        # carrying.
        GenServer.reply(waiter, :ok)
        {:noreply, %{state | waiters: Map.put(state.waiters, provider, rest)}}

      {:empty, _} ->
        current = Map.get(state.counts, provider, 0)
        {:noreply, %{state | counts: Map.put(state.counts, provider, max(0, current - 1))}}
    end
  end

  # `:infinity` doesn't enter the counters at all, so anyone outside
  # the configured limits map defaults to no cap. Unknown providers
  # are not gated - safer than asserting and crashing the harness.
  defp limit_for(provider), do: Map.get(@limits, provider, :infinity)
end
