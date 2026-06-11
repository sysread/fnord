defmodule AI.Agent.Code.TaskPlannerTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("task-planner-test")
    {:ok, project: project}
  end

  describe "planning response validation" do
    test "malformed steps do not crash and are reported as invalid_response_format", %{
      project: _project
    } do
      # Return a planning response that violates the JSON schema: steps
      # contains a string. The planner pipeline runs research and visualize
      # first (plain-text completions, response_format nil); only the plan
      # stage sends the plan_steps json_schema, so the stub keys on that
      # rather than counting calls.
      bad_response =
        SafeJson.encode!(%{
          "steps" => ["arguments"]
        })

      stub(AI.CompletionAPI.Mock, :get, fn _model, _msgs, _tools, response_format, _web, _vrb ->
        case response_format do
          %{json_schema: %{name: "plan_steps"}} -> {:ok, :msg, bad_response, 0}
          _ -> {:ok, :msg, "ok", 0}
        end
      end)

      agent = AI.Agent.new(AI.Agent.Code.TaskPlanner)

      assert {:error, :invalid_response_format} =
               AI.Agent.get_response(agent, %{request: "please plan something"})
    end
  end
end
