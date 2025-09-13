defmodule Services.Approvals.Shell.SedPreapprovedRegexTest do
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

  describe "confirm/2 with sed preapproved regex in non-interactive mode" do
    test "approves safe read-only sed commands" do
      # Simulate non-interactive terminal
      :meck.expect(UI, :is_tty?, fn -> false end)

      # -n range p
      cmd1 = %{"command" => "sed", "args" => ["-n", "10,20p", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd1], "test"})

      # -n /pattern/ p
      cmd2 = %{"command" => "sed", "args" => ["-n", "/foo/p", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd2], "test"})

      # -E s///g (no e)
      cmd3 = %{"command" => "sed", "args" => ["-E", "s/foo/bar/g", "file.txt"]}
      assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd3], "test"})
    end

    test "denies modifying sed commands" do
      :meck.expect(UI, :is_tty?, fn -> false end)

      # in-place edit
      bad1 = %{"command" => "sed", "args" => ["-i", "", "s/foo/bar/", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad1], "test"})

      # script file
      bad2 = %{"command" => "sed", "args" => ["-f", "script.sed", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad2], "test"})

      # execute flag
      bad3 = %{"command" => "sed", "args" => ["-e", "s/foo/bar/", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad3], "test"})

      # s///e execute in substitution
      bad4 = %{"command" => "sed", "args" => ["s/foo/bar/e", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad4], "test"})

      # write command w filename
      bad5 = %{"command" => "sed", "args" => ["-n", "1,10w out.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad5], "test"})

      # Write command W filename
      bad6 = %{"command" => "sed", "args" => ["W backup.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad6], "test"})

      # read file command
      bad7 = %{"command" => "sed", "args" => ["1r header.txt", "file.txt"]}
      assert {:denied, _, _} = Shell.confirm(%{session: []}, {"|", [bad7], "test"})
    end
  end
end
