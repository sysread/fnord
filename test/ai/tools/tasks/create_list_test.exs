defmodule AI.Tools.Tasks.CreateListTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("test_project_create_list_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns a function spec with correct name and no parameters" do
      spec = AI.Tools.Tasks.CreateList.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_create_list"
      assert spec.function.parameters == %{type: "object", required: [], properties: %{}}
    end
  end

  describe "call/1" do
    test "creates a new task list and returns its ID" do
      # Ensure no prior lists
      {:ok, str} = AI.Tools.Tasks.CreateList.call(%{})

      assert [_, list_id_str] = Regex.run(~r/^Task List (\d+)/, str)
      assert {list_id, ""} = Integer.parse(list_id_str)

      # Verify the list exists and is initially empty
      tasks = Services.Task.get_list(list_id)
      assert tasks == []
    end
  end
end
