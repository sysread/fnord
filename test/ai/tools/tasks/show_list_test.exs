defmodule AI.Tools.Tasks.ShowListTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("test_project_show_list_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns a function spec with correct name and parameters" do
      spec = AI.Tools.Tasks.ShowList.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_show_list"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id"]

      props = params.properties
      assert props["list_id"].type == "string"
    end
  end

  describe "read_args/1" do
    test "errors when missing list_id" do
      assert {:error, :missing_argument, "list_id"} = AI.Tools.Tasks.ShowList.read_args(%{})
    end

    test "errors when list_id is wrong type" do
      assert {:error, :invalid_argument, _} =
               AI.Tools.Tasks.ShowList.read_args(%{"list_id" => :not_a_string})
    end

    test "returns parsed map when list_id is valid" do
      assert {:ok, %{"list_id" => "42"}} = AI.Tools.Tasks.ShowList.read_args(%{"list_id" => 42})
    end
  end

  describe "call/1" do
    test "returns detailed formatted string matching Services.Task.as_string/2" do
      list_id = Services.Task.start_list()
      # add and modify tasks to produce detail
      Services.Task.add_task(list_id, "alpha", "first task")
      Services.Task.push_task(list_id, "beta", "second task")
      Services.Task.complete_task(list_id, "alpha", "done alpha")

      {:ok, result} = AI.Tools.Tasks.ShowList.call(%{"list_id" => list_id})
      expected = Services.Task.as_string(list_id, true)
      assert result == expected
    end
  end
end
