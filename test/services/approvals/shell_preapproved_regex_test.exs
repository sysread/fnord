defmodule Services.Approvals.Shell.PreapprovedRegexTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell

  setup do
    # Ensure no persisted approvals affect tests
    File.rm_rf!(Settings.settings_file())

    # Allow UI calls to pass through default implementations
    :meck.new(UI, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "confirm/2 with built-in preapproved regex" do
    test "approves find command without exec in non-interactive mode" do
      # Simulate non-interactive terminal
      :meck.expect(UI, :is_tty?, fn -> false end)

      find_cmd = %{"command" => "find", "args" => [".", "-type", "f", "-print0"]}
      result = Shell.confirm(%{session: []}, {"|", [find_cmd], "test"})

      assert {:approved, _new_state} = result
    end

    test "denies find command with exec in non-interactive mode" do
      :meck.expect(UI, :is_tty?, fn -> false end)

      exec_cmd = %{"command" => "find", "args" => [".", "-type", "f", "-exec", "rm", "{}", ";"]}
      result = Shell.confirm(%{session: []}, {"|", [exec_cmd], "test"})

      assert {:denied, _msg, _state} = result
    end
  end
end
