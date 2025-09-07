defmodule Services.Approvals.ShellFullMatchingTest do
  use Fnord.TestCase, async: false

  test "shell_full matches against basename(command)+args, not absolute path" do
    File.rm_rf!(Settings.settings_file())
    _settings = Settings.Approvals.approve(Settings.new(), :global, "shell_full", "^find\\b")

    state = %{session: []}
    op = "|"
    purpose = "test"

    :ok = :meck.new(UI, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(UI)
      catch
        _, _ -> :ok
      end
    end)

    :meck.expect(UI, :is_tty?, fn -> false end)

    # A: command basename is 'find' -> should approve
    cmd_a = %{"command" => "find", "args" => ["-type", "f", "/tmp"]}
    assert {:approved, _} = Services.Approvals.Shell.confirm(state, {op, [cmd_a], purpose})

    # B: command has absolute path; basename still 'find' -> also approves
    cmd_b = %{"command" => "/usr/bin/find", "args" => ["-type", "f", "/tmp"]}
    assert {:approved, _} = Services.Approvals.Shell.confirm(state, {op, [cmd_b], purpose})

    # C: command is 'grep'; should not approve; confirm returns denial in non-tty
    cmd_c = %{"command" => "whoami", "args" => []}
    assert {:denied, _msg, _} = Services.Approvals.Shell.confirm(state, {op, [cmd_c], purpose})
  end
end
