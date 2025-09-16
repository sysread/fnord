defmodule Settings.InstrumentationTest do
  use Fnord.TestCase

  alias Settings.Instrumentation
  alias Settings

  setup do
    # Clear ETS tables before each test
    if :ets.whereis(:fnord_approvals_baseline) != :undefined do
      :ets.delete_all_objects(:fnord_approvals_baseline)
    end

    if :ets.whereis(:fnord_approvals_traces) != :undefined do
      :ets.delete_all_objects(:fnord_approvals_traces)
    end

    # Ensure environment reset
    System.delete_env("FNORD_DEBUG_SETTINGS")

    :ok
  end

  test "debug_settings? picks up truthy env values" do
    for v <- ["1", "true", "yes", "TRUE", "Yes"] do
      System.put_env("FNORD_DEBUG_SETTINGS", v)
      assert Settings.debug_settings?(), "Expected debug_settings? to be true for \\#{v}"
    end

    System.delete_env("FNORD_DEBUG_SETTINGS")
    refute Settings.debug_settings?(), "Expected debug_settings? to be false when unset"
  end

  test "init_baseline and record_trace work" do
    data = %{"approvals" => %{"foo" => ["A", "B"]}}
    assert :ok = Instrumentation.init_baseline(data)

    # Simulate a mutation that clears approvals
    before = data
    after_data = %{"approvals" => %{}}
    assert :ok = Instrumentation.record_trace(:set, :test, before, after_data)

    # The most recent entry should reflect the counts
    [entry] = Instrumentation.recent_traces(1)
    assert entry.before_counts == %{"foo" => 2}
    assert entry.after_counts == %{"foo" => 0}
    assert entry.op == :set
    assert entry.key == :test
    assert is_integer(entry.ts)
    assert is_list(entry.stack)
  end

  test "guard_or_heal auto-heals when not debug" do
    System.delete_env("FNORD_DEBUG_SETTINGS")
    data = %{"approvals" => %{"k" => ["x"]}}
    :ok = Instrumentation.init_baseline(data)

    healed = Instrumentation.guard_or_heal(data, %{"approvals" => %{}}, %{op: :t, key: :k})
    # Should restore missing approvals
    assert healed["approvals"] == %{"k" => ["x"]}
  end

  test "guard_or_heal does not heal when debug" do
    System.put_env("FNORD_DEBUG_SETTINGS", "1")
    data = %{"approvals" => %{"k" => ["x"]}}
    :ok = Instrumentation.init_baseline(data)

    result = Instrumentation.guard_or_heal(data, %{"approvals" => %{}}, %{op: :t, key: :k})
    # In debug mode, approvals should remain cleared
    assert result == %{"approvals" => %{}}
  end
end
