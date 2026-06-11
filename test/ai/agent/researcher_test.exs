defmodule AI.Agent.ResearcherTest do
  use Fnord.TestCase, async: true

  # Researcher (the sub-agent behind research_tool) builds a fresh messages
  # list for its completion. Without the external-configs catalog threaded in
  # at construction, spawned research sub-agents run rule-blind. The canned
  # completion below captures the messages at the model boundary, after the
  # real completion loop has assembled them.
  setup do
    project = mock_project("researcher-ext-configs")
    Settings.set_project("researcher-ext-configs")
    {:ok, project: project}
  end

  test "threads the external-configs catalog into the completion messages", %{
    project: project
  } do
    Settings.ExternalConfigs.set("researcher-ext-configs", :cursor_rules, true)

    rule_path = Path.join(project.source_root, ".cursor/rules/style.mdc")
    File.mkdir_p!(Path.dirname(rule_path))

    File.write!(rule_path, """
    ---
    description: project style
    alwaysApply: true
    ---
    Always follow these style rules.
    """)

    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:captured_msgs, msgs})
      {:ok, :msg, "canned response", 0}
    end)

    agent = AI.Agent.new(AI.Agent.Researcher, named?: false)

    assert {:ok, "canned response"} =
             AI.Agent.Researcher.get_response(%{agent: agent, prompt: "dig around"})

    assert_receive {:captured_msgs, msgs}, 1000

    combined = msgs |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n---\n")

    assert combined =~ "Always follow these style rules."
    assert combined =~ "dig around"
  end

  test "emits no catalog entries when external-configs are disabled" do
    test_pid = self()

    canned_completion(fn msgs ->
      send(test_pid, {:captured_msgs, msgs})
      {:ok, :msg, "ok", 0}
    end)

    agent = AI.Agent.new(AI.Agent.Researcher, named?: false)

    assert {:ok, "ok"} =
             AI.Agent.Researcher.get_response(%{agent: agent, prompt: "q"})

    assert_receive {:captured_msgs, msgs}, 1000

    combined = msgs |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n---\n")

    refute combined =~ "Cursor rules"
    refute combined =~ "Cursor skills"
    refute combined =~ "Claude Code"
  end
end
