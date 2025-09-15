defmodule AI.Tools.Tasks.CreateListTest do
  use Fnord.TestCase, async: false

  setup do
    case Process.whereis(Services.Task) do
      nil -> Services.Task.start_link()
      _ -> :ok
    end

    :ok
  end

  alias AI.Tools.Tasks.CreateList
  alias Services.Task

  describe "spec/0" do
    test "returns a function spec with correct name and no parameters" do
      spec = CreateList.spec()

      assert spec.type == "function"
      assert spec.function.name == "tasks_create_list"
      assert spec.function.parameters == %{type: "object", required: [], properties: %{}}
    end
  end

  describe "call/1" do
    test "creates a new task list and returns its ID" do
      # Ensure no prior lists
      {:ok, str} = CreateList.call(%{})

      assert [_, list_id_str] = Regex.run(~r/^Task List (\d+)/, str)
      assert {list_id, ""} = Integer.parse(list_id_str)

      # Verify the list exists and is initially empty
      tasks = Task.get_list(list_id)
      assert tasks == []
    end
  end
end
