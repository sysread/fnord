defmodule AI.Tools.LongTermMemoryTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.LongTermMemory

  test "remember saves a project memory" do
    mock_project("ltm-test")

    args = %{
      "action" => "remember",
      "scope" => "project",
      "title" => "LTM Test",
      "content" => "persisted"
    }

    assert {:ok, resp} = LongTermMemory.call(args)
    assert String.contains?(resp, "Title: LTM Test")

    # Confirm it can be read back
    assert {:ok, mem} = Memory.read(:project, "LTM Test")
    assert mem.content == "persisted"
  end

  test "update appends content to existing memory" do
    mock_project("ltm-test-2")

    {:ok, mem} = Memory.new(:project, "Update Test", "first", [])
    {:ok, _} = Memory.save(mem)

    args = %{
      "action" => "update",
      "scope" => "project",
      "title" => "Update Test",
      "new_content" => " more"
    }

    assert {:ok, resp} = LongTermMemory.call(args)
    assert String.contains?(resp, "Title: Update Test")

    assert {:ok, mem2} = Memory.read(:project, "Update Test")
    assert String.contains?(mem2.content, "first more")
  end

  test "forget removes a memory" do
    mock_project("ltm-test-3")

    {:ok, mem} = Memory.new(:project, "Forget Test", "bye", [])
    {:ok, _} = Memory.save(mem)

    args = %{"action" => "forget", "scope" => "project", "title" => "Forget Test"}
    assert {:ok, "forgotten"} = LongTermMemory.call(args)

    assert {:error, :not_found} = Memory.read(:project, "Forget Test")
  end
end
