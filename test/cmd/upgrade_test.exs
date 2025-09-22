defmodule Cmd.UpgradeTest do
  use Fnord.TestCase
  @moduletag :capture_log

  describe "run/3" do
    test "upgrades when newer version is available and user confirms" do
      :meck.new(Util, [:no_link, :passthrough, :non_strict])
      :meck.new(UI, [:no_link, :passthrough, :non_strict])
      :meck.new(System, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Util)
        :meck.unload(UI)
        :meck.unload(System)
      end)

      :meck.expect(Util, :get_latest_version, fn -> {:ok, "1.2.3"} end)
      :meck.expect(Util, :get_running_version, fn -> "1.2.2" end)

      :meck.expect(UI, :confirm, fn msg, default ->
        assert msg == "Do you want to upgrade to the latest version of fnord?"
        refute default
        true
      end)

      :meck.expect(System, :cmd, fn "mix",
                                    ["escript.install", "--force", "github", "sysread/fnord"],
                                    opts ->
        assert Keyword.get(opts, :stderr_to_stdout) == true
        # into is a stream; just ensure key exists
        assert Keyword.has_key?(opts, :into)
        {"ok", 0}
      end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert :meck.called(System, :cmd, [
               "mix",
               ["escript.install", "--force", "github", "sysread/fnord"],
               :_
             ])

      assert stdout =~ "Current version: 1.2.2"
      assert stdout =~ "Latest version: 1.2.3"
    end

    test "reinstalls when on latest version and user confirms" do
      :meck.new(Util, [:no_link, :passthrough, :non_strict])
      :meck.new(UI, [:no_link, :passthrough, :non_strict])
      :meck.new(System, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Util)
        :meck.unload(UI)
        :meck.unload(System)
      end)

      :meck.expect(Util, :get_latest_version, fn -> {:ok, "1.2.3"} end)
      :meck.expect(Util, :get_running_version, fn -> "1.2.3" end)

      :meck.expect(UI, :confirm, fn msg, default ->
        assert msg == "You are on the latest version of fnord. Would you like to reinstall?"
        refute default
        true
      end)

      :meck.expect(System, :cmd, fn "mix",
                                    ["escript.install", "--force", "github", "sysread/fnord"],
                                    _opts ->
        {"ok", 0}
      end)

      {_stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert :meck.called(System, :cmd, [
               "mix",
               ["escript.install", "--force", "github", "sysread/fnord"],
               :_
             ])
    end

    test "cancels when newer version available but user declines" do
      :meck.new(Util, [:no_link, :passthrough, :non_strict])
      :meck.new(UI, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Util)
        :meck.unload(UI)
      end)

      :meck.expect(Util, :get_latest_version, fn -> {:ok, "1.2.3"} end)
      :meck.expect(Util, :get_running_version, fn -> "1.2.2" end)

      :meck.expect(UI, :confirm, fn msg, default ->
        assert msg == "Do you want to upgrade to the latest version of fnord?"
        refute default
        false
      end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert stdout =~ "Current version: 1.2.2"
      assert stdout =~ "Latest version: 1.2.3"
      assert stdout =~ "Cancelled"
    end

    test "handles error from get_latest_version" do
      :meck.new(Util, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Util)
      end)

      :meck.expect(Util, :get_latest_version, fn -> {:error, :api_request_failed} end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end)

      assert stdout =~ "Error checking for updates: api_request_failed"
    end

    test "raises when running version is greater than latest version" do
      :meck.new(Util, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Util)
      end)

      :meck.expect(Util, :get_latest_version, fn -> {:ok, "1.2.3"} end)
      :meck.expect(Util, :get_running_version, fn -> "1.2.4" end)

      assert_raise RuntimeError, fn -> Cmd.Upgrade.run(%{yes: false}, [], []) end
    end
  end
end
