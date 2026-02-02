defmodule AI.Tools.Tasks.CreateListTest do
  use Fnord.TestCase, async: false

  setup do
    mock_project("test_project_create_list_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns a function spec with correct name and optional id and description parameters" do
      spec = AI.Tools.Tasks.CreateList.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_create_list"
      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == []
      props = params.properties
      assert Map.has_key?(props, "id")
      assert props["id"].type == "string"
      assert Map.has_key?(props, "description")
      assert props["description"].type == "string"
    end
  end

  describe "call/1" do
    test "creates a new task list and returns its ID" do
      # Ensure no prior lists
      {:ok, str} = AI.Tools.Tasks.CreateList.call(%{})

      assert [_, list_id] = Regex.run(~r/^Task List ([^:]+)/, str)

      # Verify the list exists and is initially empty
      tasks = Services.Task.get_list(list_id)
      assert tasks == []
    end

    test "accepts optional description and includes it in output" do
      desc = "My Custom Description"
      {:ok, str} = AI.Tools.Tasks.CreateList.call(%{"description" => desc})
      # Header should include the description after the list ID
      assert str =~ ~r/^Task List ([^:]+): #{Regex.escape(desc)}/
    end

    test "accepts custom id and creates list with that id" do
      {:ok, str} = AI.Tools.Tasks.CreateList.call(%{"id" => "my-custom-list"})
      assert str =~ "Task List my-custom-list:"
      # Verify the list exists
      assert [] = Services.Task.get_list("my-custom-list")
    end

    test "returns error on duplicate custom id" do
      {:ok, _} = AI.Tools.Tasks.CreateList.call(%{"id" => "duplicate-id"})
      assert {:error, msg} = AI.Tools.Tasks.CreateList.call(%{"id" => "duplicate-id"})
      assert msg == "Task list 'duplicate-id' already exists"
    end

    test "accepts custom id with description" do
      {:ok, str} =
        AI.Tools.Tasks.CreateList.call(%{"id" => "custom-with-desc", "description" => "My desc"})

      assert str =~ "Task List custom-with-desc: My desc"
    end
  end
end
