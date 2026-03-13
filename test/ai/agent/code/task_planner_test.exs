defmodule AI.Agent.Code.TaskPlannerTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("task-planner-test")

    :meck.new(AI.Completion, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Completion)
    end)

    {:ok, project: project}
  end

  describe "planning response validation" do
    test "malformed steps do not crash and are reported as invalid_response_format", %{
      project: _project
    } do
      # Return a planning response that violates the JSON schema: steps contains a string.
      bad_response =
        SafeJson.encode!(%{
          "steps" => ["arguments"]
        })

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      :meck.expect(AI.Completion, :get, fn _opts ->
        count = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        case count do
          1 -> {:ok, %{response: "ok", messages: []}}
          2 -> {:ok, %{response: "ok", messages: []}}
          _ -> {:ok, %{response: bad_response, messages: []}}
        end
      end)

      agent = AI.Agent.new(AI.Agent.Code.TaskPlanner)

      assert {:error, :invalid_response_format} =
               AI.Agent.get_response(agent, %{request: "please plan something"})
    end
  end
end
