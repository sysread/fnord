defmodule AI.Agent.SkillTest do
  use Fnord.TestCase, async: true

  # Under the Responses API, web search is attached via the web_search?
  # completion option, not by model choice - AI.Model.web_search() is a plain
  # model. The skill agent must translate the "web" model preset into that
  # flag, or skills declaring model = "web" silently run without search. The
  # stub asserts at the completion-API boundary, so the flag is verified to
  # survive the whole trip through the real completion loop.
  describe "web search wiring for the \"web\" model preset" do
    setup do
      test_pid = self()

      stub(AI.CompletionAPI.Mock, :get, fn _model, _msgs, _tools, _rf, web_search?, _verbosity ->
        send(test_pid, {:web_search?, web_search?})
        {:ok, :msg, "ok", 0}
      end)

      :ok
    end

    test "model = \"web\" passes web_search?: true to the completion" do
      assert {:ok, "ok"} = run_skill("web")
      assert_receive {:web_search?, true}, 1000
    end

    test "other model presets pass web_search?: false" do
      assert {:ok, "ok"} = run_skill("fast")
      assert_receive {:web_search?, false}, 1000
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
