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
      assert params.required == ["list_id"]

      props = params.properties
      assert props["list_id"].type == :integer
      assert props["task_id"].type == "string"
      assert props["data"].type == "string"
      assert props["tasks"].type == "array"
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

  describe "ui_note_on_request/1" do
    test "returns {task_id, data} for single input" do
      assert PushTask.ui_note_on_request(%{"task_id" => "a", "data" => "b"}) == {"a", "b"}
    end

    test "returns {task_id, data} for single-element tasks list" do
      tasks = [%{"task_id" => "only", "data" => "x"}]
      assert PushTask.ui_note_on_request(%{"tasks" => tasks}) == {"only", "x"}
    end

    test "returns correct note and preview for multiple tasks" do
      tasks = [
        %{"task_id" => "t1", "data" => "d1"},
        %{"task_id" => "t2", "data" => "d2"},
        %{"task_id" => "t3", "data" => "d3"},
        %{"task_id" => "t4", "data" => "d4"}
      ]

      note = PushTask.ui_note_on_request(%{"tasks" => tasks})
      assert note == {"Pushing 4 tasks", "t1, t2, t3"}
    end
  end

  describe "read_args/1 batch" do
    test "normalizes single-element tasks list" do
      args = %{"list_id" => 1, "tasks" => [%{"task_id" => "a", "data" => "A"}]}
      assert {:ok, %{"list_id" => 1, "tasks" => tasks}} = PushTask.read_args(args)
      assert tasks == [%{"task_id" => "a", "data" => "A"}]
    end

    test "normalizes multi-element tasks list" do
      tasks_input = [
        %{"task_id" => "t1", "data" => "d1"},
        %{"task_id" => "t2", "data" => "d2"}
      ]

      args = %{"list_id" => 2, "tasks" => tasks_input}
      assert {:ok, %{"list_id" => 2, "tasks" => tasks}} = PushTask.read_args(args)
      assert tasks == tasks_input
    end

    test "returns error for empty tasks list" do
      args = %{"list_id" => 3, "tasks" => []}
      assert {:error, :invalid_argument, _} = PushTask.read_args(args)
    end

    test "returns error for invalid task element" do
      args = %{"list_id" => 4, "tasks" => [%{"task_id" => 1, "data" => "d"}]}
      assert {:error, :invalid_argument, _} = PushTask.read_args(args)
    end
  end

  describe "call/1 batch" do
    setup do
      list_id = Task.start_list()
      {:ok, list_id: list_id}
    end

    test "pushes multiple tasks to front preserving order", %{list_id: list_id} do
      tasks = [
        %{"task_id" => "p1", "data" => "d1"},
        %{"task_id" => "p2", "data" => "d2"},
        %{"task_id" => "p3", "data" => "d3"}
      ]

      assert {:ok, _} = PushTask.call(%{"list_id" => list_id, "tasks" => tasks})
      got = Task.get_list(list_id)
      assert Enum.map(got, & &1.id) == ["p1", "p2", "p3"]
    end
  end
end
