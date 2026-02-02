defmodule AI.Tools.Tasks.AddTaskTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("test_project_add_task_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns function spec with correct name and parameters" do
      spec = AI.Tools.Tasks.AddTask.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_add_task"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id"]

      props = params.properties
      assert props["list_id"].type == "string"
      assert props["task_id"].type == "string"
      assert props["data"].type == "string"
    end
  end

  describe "read_args/1" do
    test "returns error when required args missing" do
      assert {:error, :missing_argument, "list_id"} = AI.Tools.Tasks.AddTask.read_args(%{})
    end

    test "returns error when list_id is wrong type" do
      args = %{"list_id" => :not_a_string, "task_id" => "t", "data" => "d"}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.AddTask.read_args(args)
    end

    test "returns error when task_id is wrong type" do
      args = %{"list_id" => 1, "task_id" => 2, "data" => "d"}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.AddTask.read_args(args)
    end

    test "returns error when data is wrong type" do
      args = %{"list_id" => 1, "task_id" => "t", "data" => 123}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.AddTask.read_args(args)
    end

    test "returns parsed map when args are valid" do
      args = %{"list_id" => 1, "task_id" => "t", "data" => "d"}

      assert {:ok, %{"list_id" => "1", "tasks" => [%{"task_id" => "t", "data" => "d"}]}} =
               AI.Tools.Tasks.AddTask.read_args(args)
    end
  end

  describe "call/1" do
    setup do
      list_id = Services.Task.start_list()
      {:ok, list_id: list_id}
    end

    test "adds task to empty list", %{list_id: list_id} do
      task_id = "task1"
      data = "payload"

      assert {:ok, str} =
               AI.Tools.Tasks.AddTask.call(%{
                 "list_id" => list_id,
                 "task_id" => task_id,
                 "data" => data
               })

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[ ] #{task_id}")

      tasks = Services.Task.get_list(list_id)
      assert [%{id: ^task_id, outcome: :todo, data: ^data, result: nil}] = tasks
    end
  end

  describe "read_args/1 batch" do
    test "normalizes single-element tasks list" do
      args = %{"list_id" => 1, "tasks" => [%{"task_id" => "a", "data" => "A"}]}
      assert {:ok, %{"list_id" => "1", "tasks" => tasks}} = AI.Tools.Tasks.AddTask.read_args(args)
      assert tasks == [%{"task_id" => "a", "data" => "A"}]
    end

    test "normalizes multi-element tasks list" do
      tasks_input = [
        %{"task_id" => "t1", "data" => "d1"},
        %{"task_id" => "t2", "data" => "d2"}
      ]

      args = %{"list_id" => 2, "tasks" => tasks_input}
      assert {:ok, %{"list_id" => "2", "tasks" => tasks}} = AI.Tools.Tasks.AddTask.read_args(args)
      assert tasks == tasks_input
    end

    test "returns error for empty tasks list" do
      args = %{"list_id" => 3, "tasks" => []}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.AddTask.read_args(args)
    end

    test "returns error for invalid task element" do
      args = %{"list_id" => 4, "tasks" => [%{"task_id" => 1, "data" => "d"}]}
      assert {:error, :invalid_argument, _} = AI.Tools.Tasks.AddTask.read_args(args)
    end
  end

  describe "call/1 batch" do
    setup do
      list_id = Services.Task.start_list()
      {:ok, list_id: list_id}
    end

    test "adds multiple tasks in order", %{list_id: list_id} do
      tasks = [
        %{"task_id" => "m1", "data" => "d1"},
        %{"task_id" => "m2", "data" => "d2"},
        %{"task_id" => "m3", "data" => "d3"}
      ]

      assert {:ok, _} = AI.Tools.Tasks.AddTask.call(%{"list_id" => list_id, "tasks" => tasks})
      got = Services.Task.get_list(list_id)
      assert Enum.map(got, & &1.id) == ["m1", "m2", "m3"]
    end
  end
end
