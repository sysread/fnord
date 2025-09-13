# This test module ensures that global shell prefix approvals are honored
# for chained commands in Services.Approvals.Shell.
defmodule Services.Approvals.Shell.GlobalPrefix.Test do
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell

  setup do
    # Ensure no persisted approvals affect tests
    File.rm_rf!(Settings.settings_file())

    # Stub UI to bypass interactive prompts
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

  describe "confirm/2 honoring global shell prefix approvals for chained commands" do
    test "approves chained mix commands in non-interactive mode when prefixes approved globally" do
      # Simulate non-interactive terminal
      :meck.expect(UI, :is_tty?, fn -> false end)

      # Approve prefixes globally
      Settings.new()
      |> Settings.Approvals.approve(:global, "shell", "mix test")
      |> Settings.Approvals.approve(:global, "shell", "mix format")
      |> Settings.Approvals.approve(:global, "shell", "mix dialyzer")

      commands = [
        %{"command" => "mix", "args" => ["test"]},
        %{"command" => "mix", "args" => ["format", "--check-formatted"]},
        %{"command" => "mix", "args" => ["dialyzer"]}
      ]

      assert {:approved, _new_state} =
               Shell.confirm(%{session: []}, {"&&", commands, "running mix tasks"})
    end
  end
end
