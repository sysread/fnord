defmodule Cmd.UpgradeTest do
  use Fnord.TestCase, async: true
  @moduletag :capture_log

  # Cmd.Upgrade compares the real running version (read from the app spec)
  # against whatever hex.pm reports, so each test derives its scripted
  # "latest" relative to the version actually compiled into this suite.
  defp stub_latest_version(version) do
    stub(Http.Client.Mock, :get, fn url, _headers, _opts ->
      assert url =~ "hex.pm/api/packages/fnord"
      {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"latest_version":"#{version}"})}}
    end)
  end

  defp bump_major(version) do
    %Version{major: major} = Version.parse!(version)
    "#{major + 1}.0.0"
  end

  describe "run/3" do
    test "upgrades when newer version is available and user confirms" do
      current = Util.get_running_version()
      latest = bump_major(current)
      stub_latest_version(latest)

      stub(UI.Output.Mock, :confirm, fn msg, default ->
        assert msg == "Do you want to upgrade to the latest version of fnord?"
        refute default
        true
      end)

      test_pid = self()

      stub(Util.Exec.Mock, :cmd, fn "mix", args, opts ->
        send(test_pid, {:install, args, opts})
        {"ok", 0}
      end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert_received {:install, ["escript.install", "--force", "github", "sysread/fnord"], opts}
      assert Keyword.get(opts, :stderr_to_stdout) == true
      # into is a stream; just ensure the key exists
      assert Keyword.has_key?(opts, :into)

      assert stdout =~ "Current version: #{current}"
      assert stdout =~ "Latest version: #{latest}"
    end

    test "reinstalls when on latest version and user confirms" do
      current = Util.get_running_version()
      stub_latest_version(current)

      stub(UI.Output.Mock, :confirm, fn msg, default ->
        assert msg == "You are on the latest version of fnord. Would you like to reinstall?"
        refute default
        true
      end)

      test_pid = self()

      stub(Util.Exec.Mock, :cmd, fn "mix", args, _opts ->
        send(test_pid, {:install, args})
        {"ok", 0}
      end)

      capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert_received {:install, ["escript.install", "--force", "github", "sysread/fnord"]}
    end

    test "cancels when newer version available but user declines" do
      current = Util.get_running_version()
      latest = bump_major(current)
      stub_latest_version(latest)

      stub(UI.Output.Mock, :confirm, fn _msg, _default -> false end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert stdout =~ "Current version: #{current}"
      assert stdout =~ "Latest version: #{latest}"
      assert stdout =~ "Cancelled"
    end

    test "handles error from get_latest_version" do
      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 404, body: ""}}
      end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert stdout =~ "Error checking for updates: api_request_failed"
    end

    test "raises when running version is greater than latest version" do
      stub_latest_version("0.0.1")

      assert_raise RuntimeError, fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end
    end
  end
end
