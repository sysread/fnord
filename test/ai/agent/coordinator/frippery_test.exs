defmodule AI.Agent.Coordinator.FripperyTest do
  use Fnord.TestCase, async: false

  # Collects every UI.Output.Mock.log/2 call made while fun executes, so
  # tests that drive Frippery through multiple info lines can make
  # assertions about the whole batch rather than a single expected call.
  defp capture_ui_logs(fun) do
    {:ok, collector} = Agent.start_link(fn -> [] end)

    Mox.stub(UI.Output.Mock, :log, fn level, msg ->
      Agent.update(collector, &[{level, IO.iodata_to_binary(msg)} | &1])
      :ok
    end)

    try do
      fun.()
      Agent.get(collector, &Enum.reverse/1)
    after
      Agent.stop(collector)
    end
  end

  defp write_skill!(project, kind_dir, name) do
    skill_dir = Path.join([project.source_root, kind_dir, name])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: test
    ---
    body
    """)
  end

  describe "log_available_mcp_tools/0" do
    setup do
      mock_project("coordinator_frippery")
      :ok
    end

    test "groups MCP tools by service and sorts services and tool names" do
      :ok =
        MCP.Tools.register_server_tools("zeta", [
          %{"name" => "zap", "description" => "", "inputSchema" => %{}}
        ])

      :ok =
        MCP.Tools.register_server_tools("foo", [
          %{"name" => "baz", "description" => "", "inputSchema" => %{}},
          %{"name" => "bar", "description" => "", "inputSchema" => %{}},
          %{"name" => "bat", "description" => "", "inputSchema" => %{}}
        ])

      expect(UI.Output.Mock, :log, fn level, msg ->
        rendered = IO.iodata_to_binary(msg)

        assert level == :info
        assert rendered == "MCP tools: \nfoo( bar | bat | baz )\nzeta( zap )"
        :ok
      end)

      AI.Agent.Coordinator.Frippery.log_available_mcp_tools()
    end
  end

  describe "log_available_skills/0 with external sources" do
    setup do
      project = mock_project("ec_skills_list")
      Settings.set_project("ec_skills_list")
      ExternalConfigs.Loader.clear_cache()
      on_exit(fn -> ExternalConfigs.Loader.clear_cache() end)
      {:ok, project: project}
    end

    test "emits Cursor skills line when enabled and present", %{project: project} do
      Settings.ExternalConfigs.set("ec_skills_list", :cursor_skills, true)
      write_skill!(project, ".cursor/skills", "db-updates")
      write_skill!(project, ".cursor/skills", "log-audit")

      messages = capture_ui_logs(&AI.Agent.Coordinator.Frippery.log_available_skills/0)

      assert Enum.any?(messages, fn {_level, rendered} -> rendered == "Skills: none" end)

      assert Enum.any?(messages, fn {_level, rendered} ->
               rendered == "Cursor skills: db-updates | log-audit"
             end)
    end

    test "stays silent about a source that is disabled", %{project: project} do
      write_skill!(project, ".cursor/skills", "db-updates")
      # cursor_skills stays disabled
      messages = capture_ui_logs(&AI.Agent.Coordinator.Frippery.log_available_skills/0)

      refute Enum.any?(messages, fn {_level, rendered} ->
               String.starts_with?(rendered, "Cursor skills:")
             end)
    end

    test "stays silent about an enabled source with no files" do
      Settings.ExternalConfigs.set("ec_skills_list", :cursor_skills, true)

      messages = capture_ui_logs(&AI.Agent.Coordinator.Frippery.log_available_skills/0)

      refute Enum.any?(messages, fn {_level, rendered} ->
               String.starts_with?(rendered, "Cursor skills:")
             end)
    end

    test "Claude skills line is labeled separately", %{project: project} do
      Settings.ExternalConfigs.set("ec_skills_list", :claude_skills, true)
      write_skill!(project, ".claude/skills", "check-my-work")

      messages = capture_ui_logs(&AI.Agent.Coordinator.Frippery.log_available_skills/0)

      assert Enum.any?(messages, fn {_level, rendered} ->
               rendered == "Claude skills: check-my-work"
             end)
    end
  end

  describe "hint_disabled_external_configs/0" do
    setup do
      project = mock_project("ec_hints")
      Settings.set_project("ec_hints")
      ExternalConfigs.Loader.clear_cache()
      on_exit(fn -> ExternalConfigs.Loader.clear_cache() end)
      {:ok, project: project}
    end

    test "warns when cursor rules exist on disk but feature is disabled", %{project: project} do
      rule_path = Path.join(project.source_root, ".cursor/rules/x.mdc")
      File.mkdir_p!(Path.dirname(rule_path))

      File.write!(rule_path, """
      ---
      description: disabled-but-present
      alwaysApply: true
      ---
      body
      """)

      expect(UI.Output.Mock, :log, fn level, msg ->
        rendered = IO.iodata_to_binary(msg)
        assert level == :warning
        assert rendered =~ "Cursor rules detected"
        assert rendered =~ "fnord config external-configs enable cursor:rules"
        :ok
      end)

      AI.Agent.Coordinator.Frippery.hint_disabled_external_configs()
    end

    test "stays silent when the source is already enabled", %{project: project} do
      rule_path = Path.join(project.source_root, ".cursor/rules/x.mdc")
      File.mkdir_p!(Path.dirname(rule_path))
      File.write!(rule_path, "---\ndescription: d\nalwaysApply: true\n---\nbody\n")

      Settings.ExternalConfigs.set("ec_hints", :cursor_rules, true)

      # No UI.Output.Mock.log expectation — any call would fail the test.
      AI.Agent.Coordinator.Frippery.hint_disabled_external_configs()
    end

    test "stays silent when no files are on disk" do
      # No UI.Output.Mock.log expectation.
      AI.Agent.Coordinator.Frippery.hint_disabled_external_configs()
    end
  end
end
