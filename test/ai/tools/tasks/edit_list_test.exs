defmodule AI.Tools.Tasks.EditListTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Tasks.EditList
  alias Services.Task

  setup do
    mock_project("test_project_edit_list_tool")
    mock_conversation()
    :ok
  end

  describe "spec/0" do
    test "returns a function spec with name, list_id and description parameters" do
      spec = EditList.spec()
      assert spec.type == "function"
      assert spec.function.name == "tasks_edit_list"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["list_id", "description"]

      props = params.properties
      assert %{"list_id" => list_id_spec, "description" => desc_spec} = props
      assert list_id_spec.type == "string"
      assert desc_spec.type == "string"
    end
  end

  describe "read_args/1" do
    test "returns {:ok, args} when valid" do
      args = %{"list_id" => 1, "description" => "desc"}
      assert {:ok, parsed} = EditList.read_args(args)
      assert parsed == %{"list_id" => "1", "description" => "desc"}
    end

    test "errors when missing params" do
      assert {:error, :missing_argument, "list_id"} = EditList.read_args(%{})
    end

    test "errors when invalid types" do
      assert {:error, :invalid_argument, _} =
               EditList.read_args(%{"list_id" => :not_a_string, "description" => 1})
    end
  end

  describe "call/1" do
    setup do
      # Start a task list via Task service
      list_id = Task.start_list()
      {:ok, list_id: list_id}
    end

    test "updates existing list description and returns formatted output", %{list_id: list_id} do
      # Ensure description initially nil
      assert {:ok, nil} = Task.get_description(list_id)

      # Call tool
      {:ok, str} = EditList.call(%{"list_id" => list_id, "description" => "New desc"})
      assert str =~ ~r/^Task List #{list_id}: New desc/

      # Confirm underlying description updated
      assert {:ok, "New desc"} = Task.get_description(list_id)
    end

    test "returns error for nonexistent list" do
      assert {:error, msg} =
               EditList.call(%{"list_id" => "does-not-exist", "description" => "desc"})

      assert msg == "Task list does-not-exist not found"
    end
  end
end
