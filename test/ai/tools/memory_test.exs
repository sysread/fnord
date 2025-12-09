defmodule AI.Tools.MemoryTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Memory

  describe "spec/0" do
    test "declares the correct action enum and tool name" do
      spec = Memory.spec()

      assert spec.type == "function"
      assert spec.function.name == "memory_tool"

      params = spec.function.parameters
      assert params.type == "object"
      assert params.required == ["action"]

      actions = params.properties["action"].enum

      assert Enum.sort(actions) == Enum.sort(["list", "recall", "remember", "update", "forget"])
    end
  end

  describe "call/1 dispatch" do
    test "returns error for invalid or missing action" do
      assert {:error, msg} = Memory.call(%{"action" => "search"})
      assert msg =~ "Invalid or missing 'action'"

      assert {:error, msg2} = Memory.call(%{"action" => "bogus"})
      assert msg2 =~ "Invalid or missing 'action'"

      assert {:error, msg3} = Memory.call(%{})
      assert msg3 =~ "Invalid or missing 'action'"
    end
  end

  describe "ui_note_on_result/2 for recall" do
    test "uses @nada when recall payload is nil" do
      {title, desc} = Memory.ui_note_on_result(%{"action" => "recall"}, nil)

      assert title == "Recalled memories"
      assert desc == "Nothing! Forget my own head next if it weren't attached."
    end

    test "uses @nada when recall payload is empty string" do
      {title, desc} = Memory.ui_note_on_result(%{"action" => "recall"}, "")

      assert title == "Recalled memories"
      assert desc == "Nothing! Forget my own head next if it weren't attached."
    end

    test "formats non-empty JSON result" do
      result =
        [
          %{
            "title" => "Test Memory 1",
            "scope" => "global",
            "topics" => "foo | bar",
            "score" => 0.9,
            "content" => "Some content"
          }
        ]
        |> Jason.encode!()

      {title, desc} = Memory.ui_note_on_result(%{"action" => "recall"}, result)

      assert title == "Recalled memories"
      assert desc =~ "Test Memory 1"
      assert desc =~ "global"
      assert desc =~ "0.9"
    end
  end
end
