defmodule Cmd.Config.ExternalConfigsTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog

  setup do
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  describe "external-configs list" do
    test "shows defaults (all false) when nothing is set" do
      mock_project("demo")
      Settings.set_project("demo")

      {output, _stderr} =
        capture_all(fn -> Cmd.Config.run(%{}, [:external_configs, :list], []) end)

      assert {:ok, decoded} = SafeJson.decode(output)

      assert decoded == %{
               "cursor:rules" => false,
               "cursor:skills" => false,
               "claude:skills" => false,
               "claude:agents" => false
             }
    end

    test "reflects project data set out-of-band" do
      mock_project("demo")
      Settings.set_project("demo")
      Settings.ExternalConfigs.set("demo", :cursor_rules, true)

      {output, _stderr} =
        capture_all(fn -> Cmd.Config.run(%{}, [:external_configs, :list], []) end)

      assert {:ok, decoded} = SafeJson.decode(output)

      assert decoded == %{
               "cursor:rules" => true,
               "cursor:skills" => false,
               "claude:skills" => false,
               "claude:agents" => false
             }
    end

    test "accepts --project to inspect another project" do
      mock_project("alpha")
      mock_project("beta")
      Settings.set_project("alpha")
      Settings.ExternalConfigs.set("beta", :claude_skills, true)

      {output, _stderr} =
        capture_all(fn ->
          Cmd.Config.run(%{project: "beta"}, [:external_configs, :list], [])
        end)

      assert {:ok, decoded} = SafeJson.decode(output)

      assert decoded == %{
               "cursor:rules" => false,
               "cursor:skills" => false,
               "claude:skills" => true,
               "claude:agents" => false
             }
    end

    test "errors cleanly without project context" do
      log = capture_log(fn -> Cmd.Config.run(%{}, [:external_configs, :list], []) end)
      assert log =~ "Project not specified or not found"
    end

    test "errors cleanly when --project names an unknown project" do
      log =
        capture_log(fn ->
          Cmd.Config.run(%{project: "ghost"}, [:external_configs, :list], [])
        end)

      assert log =~ "Project not found"
    end
  end

  describe "external-configs enable / disable" do
    test "enable flips a source to true and echoes the full flag set" do
      mock_project("demo")
      Settings.set_project("demo")

      {output, _stderr} =
        capture_all(fn ->
          Cmd.Config.run(%{}, [:external_configs, :enable], ["cursor:rules"])
        end)

      assert {:ok, decoded} = SafeJson.decode(output)

      assert decoded == %{
               "cursor:rules" => true,
               "cursor:skills" => false,
               "claude:skills" => false,
               "claude:agents" => false
             }

      assert Settings.ExternalConfigs.enabled?("demo", :cursor_rules)
    end

    test "disable flips a source back to false" do
      mock_project("demo")
      Settings.set_project("demo")
      Settings.ExternalConfigs.set("demo", :claude_skills, true)

      {output, _stderr} =
        capture_all(fn ->
          Cmd.Config.run(%{}, [:external_configs, :disable], ["claude:skills"])
        end)

      assert {:ok, decoded} = SafeJson.decode(output)

      assert decoded == %{
               "cursor:rules" => false,
               "cursor:skills" => false,
               "claude:skills" => false,
               "claude:agents" => false
             }

      refute Settings.ExternalConfigs.enabled?("demo", :claude_skills)
    end

    test "rejects unknown source names" do
      mock_project("demo")
      Settings.set_project("demo")

      log =
        capture_log(fn ->
          Cmd.Config.run(%{}, [:external_configs, :enable], ["bogus"])
        end)

      assert log =~ "Invalid source"
      assert log =~ "cursor:rules"
    end

    test "also rejects the old underscore spelling" do
      mock_project("demo")
      Settings.set_project("demo")

      log =
        capture_log(fn ->
          Cmd.Config.run(%{}, [:external_configs, :enable], ["cursor_rules"])
        end)

      assert log =~ "Invalid source"
    end

    test "requires the source positional argument" do
      mock_project("demo")
      Settings.set_project("demo")

      log =
        capture_log(fn ->
          Cmd.Config.run(%{}, [:external_configs, :enable], [])
        end)

      assert log =~ "Source"
    end
  end
end
