defmodule AI.Embeddings.PoolTest do
  use Fnord.TestCase, async: false

  alias AI.Embeddings.Pool

  # These tests drive the Pool's `handle_info({port, {:data, _}})` callback
  # directly with a hand-built state and a fake port term. The data clause
  # matches on `state.port` without an `is_port` guard, so no real `embed.exs`
  # process is spawned - which is deliberate, since the module avoids the cost
  # and noise of a live embed process under test.
  #
  # The behavior under test is the cold-start reframing: while the embed
  # process is still compiling/downloading, its build progress arrives on
  # stdout as undecodable lines and must NOT be treated as a fault.

  @port :fake_port

  defp base_state(overrides) do
    %{
      port: @port,
      ref: nil,
      workers: 8,
      pending: %{},
      next_id: 0,
      buffer: "",
      ready?: false,
      cold_notice_shown?: false,
      shutting_down?: false
    }
    |> Map.merge(Map.new(overrides))
  end

  defp feed(state, line) do
    {:noreply, new_state} = Pool.handle_info({@port, {:data, line <> "\n"}}, state)
    new_state
  end

  test "cold-start build noise flips the one-time notice but not readiness" do
    state = base_state([])

    state = feed(state, "==> nimble_pool")
    assert state.cold_notice_shown?
    refute state.ready?

    # A second noisy line does not re-arm the notice and still isn't a fault.
    state = feed(state, "Compiling 2 files (.ex)")
    assert state.cold_notice_shown?
    refute state.ready?
  end

  test "a well-formed embedding response marks the process ready" do
    ref = make_ref()
    from = {self(), ref}
    state = base_state(pending: %{"0" => from})

    line = SafeJson.encode!(%{"id" => "0", "embedding" => [0.1, 0.2, 0.3]})
    state = feed(state, line)

    assert state.ready?
    assert state.pending == %{}
    assert_receive {^ref, {:ok, [0.1, 0.2, 0.3]}}
  end

  test "an error response also marks the process ready and replies to the caller" do
    ref = make_ref()
    from = {self(), ref}
    state = base_state(pending: %{"0" => from})

    line = SafeJson.encode!(%{"id" => "0", "error" => "boom"})
    state = feed(state, line)

    assert state.ready?
    assert_receive {^ref, {:error, "boom"}}
  end

  test "undecodable output after readiness is treated as anomalous, not setup noise" do
    # Once ready, the notice machinery stays untouched - the line is a genuine
    # protocol anomaly (handled by the warn path), not cold-start progress.
    state = base_state(ready?: true)

    state = feed(state, "this is not json")

    assert state.ready?
    refute state.cold_notice_shown?
  end
end
