defmodule AI.Tools.Tasks.ShowListTest do
  use Fnord.TestCase, async: false

  setup do
    case Process.whereis(Services.Task) do
      nil -> Services.Task.start_link()
      _ -> :ok
    end

    :ok
  end

  alias AI.Tools.Tasks.ShowList
  alias Services.Task

  describe "spec/0" do
    test "returns a function spec with correct name and parameters" do
      spec = ShowList.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_show_list"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id"]

      props = params.properties
      assert props["list_id"].type == :integer
    end
  end

  describe "read_args/1" do
    test "errors when missing list_id" do
      assert {:error, :missing_argument, "list_id"} = ShowList.read_args(%{})
    end

    test "errors when list_id is wrong type" do
      assert {:error, :invalid_argument, _} = ShowList.read_args(%{"list_id" => "x"})
    end

    test "returns parsed map when list_id is valid" do
      assert {:ok, %{"list_id" => 42}} = ShowList.read_args(%{"list_id" => 42})
    end
  end

  describe "call/1" do
    test "returns detailed formatted string matching Services.Task.as_string/2" do
      list_id = Task.start_list()
      # add and modify tasks to produce detail
      Task.add_task(list_id, "alpha", "first task")
      Task.push_task(list_id, "beta", "second task")
      Task.complete_task(list_id, "alpha", "done alpha")

      {:ok, result} = ShowList.call(%{"list_id" => list_id})
      expected = Task.as_string(list_id, true)
      assert result == expected
    end
  end
end
