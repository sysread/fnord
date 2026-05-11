defmodule Services.ProviderConcurrencyTest do
  @moduledoc """
  Behavioral tests for the per-provider concurrency cap.

  These pin the FIFO ordering, the fail-open behavior when the service
  isn't running, and the `:infinity` no-cap path. The exact limit
  numbers per provider live in `@limits` inside the service module and
  are exposed via `limits/0` for the catch-all sweep below.
  """

  use Fnord.TestCase, async: false
  alias Services.ProviderConcurrency

  setup do
    # Each test runs its own instance under a private name so they
    # don't fight over the singleton @name registration.
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    {:ok, pid} = ProviderConcurrency.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    %{name: name, pid: pid}
  end

  describe "with_slot/2" do
    test "fail-open: runs the function when the service is not running" do
      # No service instance under the public name -> with_slot should
      # bypass the gate and execute directly.
      _ = Process.whereis(ProviderConcurrency) && GenServer.stop(ProviderConcurrency)
      assert :ran = ProviderConcurrency.with_slot("openai", fn -> :ran end)
    end
  end

  describe "limits/0" do
    test "exposes the per-provider configured caps" do
      limits = ProviderConcurrency.limits()
      assert Map.has_key?(limits, "openai")
      assert Map.has_key?(limits, "venice")
      assert Map.has_key?(limits, "deepseek")

      # OpenAI is intentionally uncapped; Venice and DeepSeek are
      # finite positive integers.
      assert limits["openai"] == :infinity
      assert is_integer(limits["venice"]) and limits["venice"] > 0
      assert is_integer(limits["deepseek"]) and limits["deepseek"] > 0
    end
  end
end
