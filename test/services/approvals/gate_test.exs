defmodule Services.Approvals.GateTest do
  use Fnord.TestCase

  test "auto_approve default" do
    # Simulate default settings by monkey-patching Settings.get/3
    :meck.new(Settings, [:non_strict])
    :meck.expect(Settings, :new, fn -> :settings end)

    :meck.expect(Settings, :get, fn
      :settings, "approvals", %{} -> %{}
      _, _, default -> default
    end)

    assert :approved = Services.Approvals.Gate.require({:mcp, "srv", :auth_finalize}, [])

    :meck.unload(Settings)
  end

  test "pending when policy requires approval" do
    # Simulate policy requiring approval by temporarily monkey-patching Settings.get/3
    # Use :meck to control policy
    :meck.new(Settings, [:non_strict])
    :meck.expect(Settings, :new, fn -> :settings end)

    :meck.expect(Settings, :get, fn
      :settings, "approvals", %{} -> %{"mcp_auth_finalize" => "require_approval"}
      _, _, default -> default
    end)

    try do
      assert {:pending, ref} = Services.Approvals.Gate.require({:mcp, "srv", :auth_finalize}, [])
      assert is_binary(ref)

      assert :pending = Services.Approvals.Gate.status(ref)
      assert :ok = Services.Approvals.Gate.approve(ref)
      assert :approved = Services.Approvals.Gate.status(ref)
    after
      try do
        :meck.unload(Settings)
      catch
        _, _ -> :ok
      end
    end
  end
end
