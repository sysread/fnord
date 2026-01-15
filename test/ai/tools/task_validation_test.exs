defmodule AI.Tools.TaskValidationTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.TaskValidation

  describe "call/1 argument validation" do
    test "errors when task_list_id is missing" do
      assert {:error, :missing_argument, "task_list_id"} =
               TaskValidation.call(%{"requirements" => "reqs"})
    end

    test "errors when requirements is missing" do
      assert {:error, :missing_argument, "requirements"} =
               TaskValidation.call(%{"task_list_id" => "1"})
    end
  end

  describe "call/1 change_summary selection" do
    test "uses explicit change_summary when provided" do
      # Stub out the downstream agent call so we can assert the payload.
      :meck.new(AI.Agent, [:passthrough])

      :meck.expect(AI.Agent, :new, fn impl, _opts ->
        %AI.Agent{name: "tester", named?: false, impl: impl}
      end)

      :meck.expect(AI.Agent, :get_response, fn _agent, payload ->
        {:ok, payload}
      end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Agent)
        catch
          _, _ -> :ok
        end
      end)

      args = %{
        "task_list_id" => "123",
        "requirements" => "reqs",
        "change_summary" => "already computed"
      }

      assert {:ok, payload} = TaskValidation.call(args)
      assert payload.task_list_id == "123"
      assert payload.requirements == "reqs"
      assert payload.change_summary == "already computed"
    end

    test "computes change_summary from Services.Task.as_string/2 when not provided" do
      # Start mock conversation/task service so Services.Task.as_string/2 has a list.
      Fnord.TestCase.mock_project("task-validation")
      %{task_pid: _task_pid} = Fnord.TestCase.mock_conversation()

      list_id = Services.Task.start_list()
      Services.Task.add_task(list_id, "do thing", "payload")

      :meck.new(AI.Agent, [:passthrough])

      :meck.expect(AI.Agent, :new, fn impl, _opts ->
        %AI.Agent{name: "tester", named?: false, impl: impl}
      end)

      :meck.expect(AI.Agent, :get_response, fn _agent, payload ->
        {:ok, payload}
      end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Agent)
        catch
          _, _ -> :ok
        end
      end)

      args = %{
        "task_list_id" => Integer.to_string(list_id),
        "requirements" => "reqs"
      }

      assert {:ok, payload} = TaskValidation.call(args)
      assert payload.task_list_id == Integer.to_string(list_id)
      assert payload.requirements == "reqs"
      assert is_binary(payload.change_summary)
      assert payload.change_summary =~ "Task List #{list_id}:"
      assert payload.change_summary =~ "do thing"
    end
  end
end
