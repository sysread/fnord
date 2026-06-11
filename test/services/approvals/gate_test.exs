defmodule Services.Approvals.GateTest do
  use Fnord.TestCase, async: true

  # The gate reads its policy from the real settings file, which lives under
  # the per-test HOME - policy is configured by writing it, not by mocking
  # the settings reader.

  test "auto_approve default" do
    # Fresh settings carry no "approvals" policy, so the gate auto-approves.
    assert :approved = Services.Approvals.Gate.require({:mcp, "srv", :auth_finalize}, [])
  end

  test "pending when policy requires approval" do
    Settings.new()
    |> Settings.update("approvals", fn _ -> %{"mcp_auth_finalize" => "require_approval"} end)

    assert {:pending, ref} = Services.Approvals.Gate.require({:mcp, "srv", :auth_finalize}, [])
    assert is_binary(ref)

    assert :pending = Services.Approvals.Gate.status(ref)
    assert :ok = Services.Approvals.Gate.approve(ref)
    assert :approved = Services.Approvals.Gate.status(ref)
  end
end
