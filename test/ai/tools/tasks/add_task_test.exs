defmodule AI.Tools.Tasks.AddTaskTest do
  use Fnord.TestCase, async: false

  setup do
    case Process.whereis(Services.Task) do
      nil -> Services.Task.start_link()
      _ -> :ok
    end

    :ok
  end

  alias AI.Tools.Tasks.AddTask
  alias Services.Task

  describe "spec/0" do
    test "returns function spec with correct name and parameters" do
      spec = AddTask.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_add_task"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id", "task_id", "data"]

      props = params.properties
      assert props["list_id"].type == :integer
      assert props["task_id"].type == "string"
      assert props["data"].type == "string"
    end
  end

  describe "read_args/1" do
    test "returns error when required args missing" do
      assert {:error, :missing_argument, "list_id"} = AddTask.read_args(%{})
    end

    test "returns error when list_id is wrong type" do
      args = %{"list_id" => "not_an_int", "task_id" => "t", "data" => "d"}
      assert {:error, :invalid_argument, _} = AddTask.read_args(args)
    end

    test "returns error when task_id is wrong type" do
      args = %{"list_id" => 1, "task_id" => 2, "data" => "d"}
      assert {:error, :invalid_argument, _} = AddTask.read_args(args)
    end

    test "returns error when data is wrong type" do
      args = %{"list_id" => 1, "task_id" => "t", "data" => 123}
      assert {:error, :invalid_argument, _} = AddTask.read_args(args)
    end

    test "returns parsed map when args are valid" do
      args = %{"list_id" => 1, "task_id" => "t", "data" => "d"}
      assert {:ok, %{"list_id" => 1, "task_id" => "t", "data" => "d"}} = AddTask.read_args(args)
    end
  end

  describe "call/1" do
    setup do
      list_id = Task.start_list()
      {:ok, list_id: list_id}
    end

    test "adds task to empty list", %{list_id: list_id} do
      task_id = "task1"
      data = "payload"

      assert {:ok, str} =
               AddTask.call(%{"list_id" => list_id, "task_id" => task_id, "data" => data})

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[ ] #{task_id}")

      tasks = Task.get_list(list_id)
      assert [%{id: ^task_id, outcome: :todo, data: ^data, result: nil}] = tasks
    end
  end
end
