defmodule Settings.SetProjectLoggingTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog
  alias Logger

  test "set_project logs only once when setting same project twice" do
    orig = Logger.level()
    Logger.configure(level: :debug)
    log =
      capture_log(fn ->
        Settings.set_project("voltron")
        Settings.set_project("voltron")
      end)
    Logger.configure(level: orig)

    matches =
      log
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "Project selected"))

    assert length(matches) == 1
  end
end
