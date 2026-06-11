defmodule AI.Agent.Dispatcher do
  @moduledoc """
  The seam between `AI.Agent.get_response/2`'s bookkeeping (name checkout,
  task wrapping, HTTP pool propagation) and the agent implementation's
  `get_response/1`. Production dispatches straight to the impl module; tests
  inject a Mox mock via the `:agent_dispatcher` Globals key (see
  `Fnord.TestCase.canned_agent/1`) to canned-respond for specific agents
  while the bookkeeping still runs for real.

  Unlike the `:http_client` and `:completion_api` seams, tests do NOT default
  this key to a mock: most tests want real agents driven by canned model
  responses, and the no-unmocked-network guarantee already lives at those
  lower layers.
  """

  @callback dispatch(module, map) :: {:ok, any} | {:error, any}

  @behaviour __MODULE__

  @doc """
  Invoke the agent implementation. `args` already carries the `%AI.Agent{}`
  under `:agent` (so `impl == args.agent.impl`); the module is passed
  separately so test stubs can pattern-match the agent being dispatched.
  """
  @impl __MODULE__
  def dispatch(impl, args), do: impl.get_response(args)

  @spec impl() :: module
  def impl() do
    Services.Globals.get_env(:fnord, :agent_dispatcher) || __MODULE__
  end
end
