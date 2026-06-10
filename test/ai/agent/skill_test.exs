defmodule AI.Agent.SkillTest do
  use Fnord.TestCase, async: false

  # Under the Responses API, web search is attached via the web_search?
  # completion option, not by model choice - AI.Model.web_search() is a plain
  # model. The skill agent must translate the "web" model preset into that
  # flag, or skills declaring model = "web" silently run without search.
  describe "web search wiring for the \"web\" model preset" do
    setup do
      :meck.new(AI.Agent, [:no_link, :passthrough])

      :meck.expect(AI.Agent, :get_completion, fn _agent, _args ->
        {:ok, %{response: "ok"}}
      end)

      on_exit(fn -> :meck.unload(AI.Agent) end)
      :ok
    end

    test "model = \"web\" passes web_search?: true to the completion" do
      assert {:ok, "ok"} = run_skill("web")

      args = :meck.capture(:first, AI.Agent, :get_completion, :_, 2)
      assert Keyword.get(args, :web_search?) == true
    end

    test "other model presets pass web_search?: false" do
      assert {:ok, "ok"} = run_skill("fast")

      args = :meck.capture(:first, AI.Agent, :get_completion, :_, 2)
      assert Keyword.get(args, :web_search?) == false
    end
  end

  defp run_skill(model) do
    skill = %Skills.Skill{
      name: "test_skill",
      description: "a test skill",
      model: model,
      tools: ["basic"],
      system_prompt: "do the thing",
      response_format: nil
    }

    agent = AI.Agent.new(AI.Agent.Skill, named?: false)

    AI.Agent.Skill.get_response(%{
      agent: agent,
      skill: skill,
      prompt: "hello"
    })
  end
end
