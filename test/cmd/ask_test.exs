defmodule Cmd.AskTest do
  use Fnord.TestCase, async: true

  setup do
    # Ensure no prior auto_policy
    Application.delete_env(:fnord, :auto_policy)
    :ok
  end

  test "default auto policy is deny after 180_000 ms when no flags provided" do
    opts = %{}
    # Apply the default policy
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 180_000}
  end

  test "auto deny override uses provided seconds" do
    opts = %{auto_deny_after: 5}
    # Validate flags first
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 5_000}
  end

  test "auto approve override uses provided seconds" do
    opts = %{auto_approve_after: 2}
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:approve, 2_000}
  end

  test "mutually exclusive auto flags returns error" do
    opts = %{auto_approve_after: 1, auto_deny_after: 2}
    assert {:error, _msg} = apply(Cmd.Ask, :validate_auto, [opts])
  end

  test "invalid auto flag values return error" do
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_approve_after: 0}])
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_deny_after: -1}])
  end
end
