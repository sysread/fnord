defmodule AI.Tools.Tasks.PushTaskTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Tasks.PushTask
  alias Services.Task

  describe "spec/0" do
    test "returns function spec with correct name and parameters" do
      spec = PushTask.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_push_task"

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
    test "errors when required args missing" do
      assert {:error, :missing_argument, "list_id"} = PushTask.read_args(%{})
    end

    test "errors when types are invalid" do
      args = %{"list_id" => "x", "task_id" => 1, "data" => 2}
      assert {:error, :invalid_argument, _} = PushTask.read_args(args)
    end

    test "returns parsed map when args are valid" do
      args = %{"list_id" => 1, "task_id" => "t", "data" => "d"}
      assert {:ok, %{"list_id" => 1, "task_id" => "t", "data" => "d"}} = PushTask.read_args(args)
    end
  end

  describe "call/1" do
    setup do
      list_id = Task.start_list()
      {:ok, list_id: list_id}
    end

    test "push onto empty list", %{list_id: list_id} do
      task_id = "first"
      data = "payload1"

      assert {:ok, str} =
               PushTask.call(%{"list_id" => list_id, "task_id" => task_id, "data" => data})

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[ ] #{task_id}")

      tasks = Task.get_list(list_id)
      assert [%{id: ^task_id, outcome: :todo, data: ^data, result: nil}] = tasks
    end

    test "push onto non-empty list puts new task first", %{list_id: list_id} do
      # Add initial task to end
      Task.add_task(list_id, "base", "base_data")

      # Push new task to front
      new_id = "pushed"
      new_data = "payload2"

      assert {:ok, str} =
               PushTask.call(%{"list_id" => list_id, "task_id" => new_id, "data" => new_data})

      assert String.starts_with?(str, "Task List #{list_id}:")
      assert String.contains?(str, "[ ] #{new_id}")

      tasks = Task.get_list(list_id)
      # Expect pushed to be first, then base
      assert [%{id: ^new_id}, %{id: "base"}] = Enum.map(tasks, fn t -> %{id: t.id} end)
    end
  end
end
