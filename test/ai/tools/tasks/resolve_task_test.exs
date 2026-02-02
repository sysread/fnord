defmodule AI.Tools.Tasks.ResolveTaskTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("test_project_resolve_task_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns function spec with correct name and parameters" do
      spec = AI.Tools.Tasks.ResolveTask.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_resolve_task"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id", "task_id", "disposition", "result"]

      props = params.properties
      assert props["list_id"].type == "string"
      assert props["task_id"].type == "string"
      assert props["disposition"].enum == ["success", "failure"]
      assert props["result"].type == "string"
    end
  end

  describe "read_args/1" do
    test "errors when required args missing" do
      assert {:error, :missing_argument, "list_id"} = AI.Tools.Tasks.ResolveTask.read_args(%{})
    end

    test "errors when types are invalid" do
      args = %{"list_id" => :not_a_string, "task_id" => 1, "disposition" => 2, "result" => 3}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.ResolveTask.read_args(args)
    end

    test "errors when disposition is invalid" do
      args = %{"list_id" => 1, "task_id" => "t", "disposition" => "meh", "result" => "r"}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.ResolveTask.read_args(args)
    end

    test "returns parsed map when args are valid" do
      args = %{"list_id" => 1, "task_id" => "t", "disposition" => "success", "result" => "ok"}
      assert {:ok, parsed} = AI.Tools.Tasks.ResolveTask.read_args(args)

      assert parsed == %{
               "list_id" => "1",
               "task_id" => "t",
               "disposition" => "success",
               "result" => "ok"
             }
    end
  end

  describe "call/1" do
    setup do
      list_id = Services.Task.start_list()
      # seed two tasks
      :ok = Services.Task.add_task(list_id, "t1", "d1")
      :ok = Services.Task.add_task(list_id, "t2", "d2")
      {:ok, list_id: list_id}
    end

    test "resolves a task with success", %{list_id: list_id} do
      assert {:ok, str} =
               AI.Tools.Tasks.ResolveTask.call(%{
                 "list_id" => list_id,
                 "task_id" => "t1",
                 "disposition" => "success",
                 "result" => "done"
               })

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[✓] t1")

      tasks = Services.Task.get_list(list_id)
      assert [%{id: "t1", outcome: :done, result: "done"}, %{id: "t2", outcome: :todo}] = tasks
    end

    test "resolves a task with failure", %{list_id: list_id} do
      assert {:ok, str} =
               AI.Tools.Tasks.ResolveTask.call(%{
                 "list_id" => list_id,
                 "task_id" => "t2",
                 "disposition" => "failure",
                 "result" => "nope"
               })

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[✗] t2")

      tasks = Services.Task.get_list(list_id)
      # t1 untouched (todo), t2 failed
      assert [%{id: "t1", outcome: :todo}, %{id: "t2", outcome: :failed, result: "nope"}] = tasks
    end
  end
end
