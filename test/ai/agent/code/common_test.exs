defmodule AI.Agent.Code.CommonTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Code.Common

  # Common.new/5 is the message-list constructor shared by TaskPlanner,
  # TaskImplementor, and TaskValidator. Verifying the external-configs
  # catalog is threaded in here covers all three sub-agent types.
  describe "new/5 with external-configs enabled" do
    setup do
      project = mock_project("common-ext-configs")
      Settings.set_project("common-ext-configs")
      ExternalConfigs.Loader.clear_cache()
      on_exit(fn -> ExternalConfigs.Loader.clear_cache() end)
      {:ok, project: project}
    end

    test "injects always-apply cursor rule bodies into the messages list", %{project: project} do
      Settings.ExternalConfigs.set("common-ext-configs", :cursor_rules, true)

      rule_path = Path.join(project.source_root, ".cursor/rules/style.mdc")
      File.mkdir_p!(Path.dirname(rule_path))

      File.write!(rule_path, """
      ---
      description: project style
      alwaysApply: true
      ---
      Always follow these style rules.
      """)

      state = Common.new(make_dummy_agent(), dummy_model(), %{}, "sys", "user")
      combined = messages_as_text(state.messages)

      assert combined =~ "always-applied"
      assert combined =~ "Always follow these style rules."
      assert combined =~ "sys"
      assert combined =~ "user"
    end

    test "injects Cursor skills catalog entries", %{project: project} do
      Settings.ExternalConfigs.set("common-ext-configs", :cursor_skills, true)

      skill_path = Path.join(project.source_root, ".cursor/skills/db-updates/SKILL.md")
      File.mkdir_p!(Path.dirname(skill_path))

      File.write!(skill_path, """
      ---
      name: db-updates
      description: how to update the db
      ---
      body
      """)

      state = Common.new(make_dummy_agent(), dummy_model(), %{}, "sys", "user")
      combined = messages_as_text(state.messages)

      assert combined =~ "Cursor skills"
      assert combined =~ "db-updates"
      assert combined =~ "how to update the db"
    end

    test "injects Claude Code subagent catalog entries", %{project: project} do
      Settings.ExternalConfigs.set("common-ext-configs", :claude_agents, true)

      agent_path = Path.join(project.source_root, ".claude/agents/review-pedantic.md")
      File.mkdir_p!(Path.dirname(agent_path))

      File.write!(agent_path, """
      ---
      name: review-pedantic
      description: Mechanical-correctness specialist.
      tools: Bash, Read, Grep
      ---
      Agent body.
      """)

      state = Common.new(make_dummy_agent(), dummy_model(), %{}, "sys", "user")
      combined = messages_as_text(state.messages)

      assert combined =~ "Claude Code subagents"
      assert combined =~ "review-pedantic"
    end

    test "emits no catalog messages when all external-configs are disabled" do
      state = Common.new(make_dummy_agent(), dummy_model(), %{}, "sys", "user")
      combined = messages_as_text(state.messages)

      refute combined =~ "Cursor skills"
      refute combined =~ "Cursor rules"
      refute combined =~ "Claude Code skills"
      refute combined =~ "Claude Code subagents"
    end

    test "user message is last so the LLM still sees the task as final input", %{
      project: project
    } do
      Settings.ExternalConfigs.set("common-ext-configs", :cursor_rules, true)

      rule_path = Path.join(project.source_root, ".cursor/rules/x.mdc")
      File.mkdir_p!(Path.dirname(rule_path))
      File.write!(rule_path, "---\ndescription: d\nalwaysApply: true\n---\nrule body\n")

      state = Common.new(make_dummy_agent(), dummy_model(), %{}, "sys", "USER_TASK")
      last = List.last(state.messages)

      assert Map.get(last, :role) == "user"
      assert Map.get(last, :content) == "USER_TASK"
    end
  end

  # Common.new takes an AI.Agent struct and a model; for this test we only
  # care that the struct accepts them without inspection.
  defp make_dummy_agent, do: %AI.Agent{name: nil, named?: false, impl: nil}
  defp dummy_model, do: %AI.Model{model: "test", context: 1024, reasoning: nil, verbosity: nil}

  defp messages_as_text(messages) do
    messages
    |> Enum.map(fn msg -> Map.get(msg, :content, "") end)
    |> Enum.join("\n---\n")
  end
end
