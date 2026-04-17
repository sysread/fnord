defmodule AI.Agent.ResearcherTest do
  use Fnord.TestCase, async: false

  # Researcher (the sub-agent behind research_tool) builds a fresh messages
  # list and passes it directly to AI.Agent.get_completion. Without the
  # external-configs catalog threaded in at construction, spawned research
  # sub-agents run rule-blind. This asserts the catalog is present in the
  # opts delivered to get_completion.
  setup do
    project = mock_project("researcher-ext-configs")
    Settings.set_project("researcher-ext-configs")
    ExternalConfigs.Loader.clear_cache()

    :meck.new(AI.Agent, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Agent)
      ExternalConfigs.Loader.clear_cache()
    end)

    {:ok, project: project}
  end

  test "threads the external-configs catalog into get_completion's messages", %{
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

    # Non-passthrough stub that captures the opts for inspection.
    test_pid = self()

    :meck.expect(AI.Agent, :get_completion, fn _agent, opts ->
      send(test_pid, {:captured_opts, opts})
      {:ok, %{response: "canned response"}}
    end)

    agent = AI.Agent.new(AI.Agent.Researcher, named?: false)

    assert {:ok, "canned response"} =
             AI.Agent.Researcher.get_response(%{agent: agent, prompt: "dig around"})

    assert_receive {:captured_opts, opts}, 1000

    messages = Keyword.fetch!(opts, :messages)
    combined = messages |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n---\n")

    assert combined =~ "Always follow these style rules."
    assert combined =~ "dig around"
  end

  test "emits no catalog entries when external-configs are disabled" do
    test_pid = self()

    :meck.expect(AI.Agent, :get_completion, fn _agent, opts ->
      send(test_pid, {:captured_opts, opts})
      {:ok, %{response: "ok"}}
    end)

    agent = AI.Agent.new(AI.Agent.Researcher, named?: false)

    assert {:ok, "ok"} =
             AI.Agent.Researcher.get_response(%{agent: agent, prompt: "q"})

    assert_receive {:captured_opts, opts}, 1000

    messages = Keyword.fetch!(opts, :messages)
    combined = messages |> Enum.map(&Map.get(&1, :content, "")) |> Enum.join("\n---\n")

    refute combined =~ "Cursor rules"
    refute combined =~ "Cursor skills"
    refute combined =~ "Claude Code"
  end
end
