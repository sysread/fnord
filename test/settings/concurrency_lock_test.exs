defmodule Settings.ConcurrencyLockTest do
  use Fnord.TestCase

  alias Settings
  alias Settings.Approvals

  setup do
    # Ensure a clean settings file for each test
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  test "two concurrent prefix approvals both survive" do
    prefixes = ["mix foo", "mix bar"]

    tasks =
      for prefix <- prefixes do
        Task.async(fn ->
          Settings.new()
          |> Approvals.approve(:global, "shell", prefix)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 15_000))

    got = Approvals.get_approvals(Settings.new(), :global, "shell")
    assert Enum.sort(got) == Enum.sort(prefixes)
  end

  test "two concurrent regex approvals both survive" do
    patterns = ["foo.*", "bar.*"]

    tasks =
      for pat <- patterns do
        Task.async(fn ->
          Settings.new()
          |> Approvals.approve(:global, "shell_full", pat)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 15_000))

    got = Approvals.get_approvals(Settings.new(), :global, "shell_full")
    assert Enum.sort(got) == Enum.sort(patterns)
  end
end
