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

  describe "ui_note_on_result/2" do
    test "returns nil (UI result notes are no longer emitted)" do
      assert Memory.ui_note_on_result(%{"action" => "recall"}, nil) == nil
      assert Memory.ui_note_on_result(%{"action" => "recall"}, "") == nil

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

      assert Memory.ui_note_on_result(%{"action" => "recall"}, result) == nil
    end
  end

  describe "perform_tool_call/3 invalid-title behavior" do
    test "remember returns unhelpful invalid_title error today" do
      assert {:error, msg} =
               AI.Tools.perform_tool_call(
                 "memory_tool",
                 %{
                   "action" => "remember",
                   "scope" => "global",
                   "title" => " ",
                   "content" => "x"
                 },
                 AI.Tools.tools()
               )

      assert msg =~ "Invalid memory title"
      assert msg =~ "Reasons:"
      assert msg =~ "Examples of valid titles"
      assert msg =~ inspect(" ")
    end
  end

  describe "remember topics normalization" do
    test "accepts topics as comma-separated string" do
      mock_project("test_proj")
      mock_conversation()

      assert {:ok, result} =
               AI.Tools.perform_tool_call(
                 "memory_tool",
                 %{
                   "action" => "remember",
                   "scope" => "session",
                   "title" => "Topics CSV Comma",
                   "content" => "x",
                   "topics" => "user, ci, troubleshooting"
                 },
                 AI.Tools.tools()
               )

      assert result =~ "Topics: user | ci | troubleshooting"
      # cleanup
      case AI.Tools.perform_tool_call(
             "memory_tool",
             %{
               "action" => "forget",
               "scope" => "session",
               "title" => "Topics CSV Comma"
             },
             AI.Tools.tools()
           ) do
        {:ok, _} -> :ok
        _ -> :ok
      end
    end

    test "accepts topics as pipe-separated string" do
      mock_project("test_proj")
      mock_conversation()

      assert {:ok, result} =
               AI.Tools.perform_tool_call(
                 "memory_tool",
                 %{
                   "action" => "remember",
                   "scope" => "session",
                   "title" => "Topics CSV Pipe",
                   "content" => "x",
                   "topics" => "user | ci | troubleshooting"
                 },
                 AI.Tools.tools()
               )

      assert result =~ "Topics: user | ci | troubleshooting"
      refute result =~ "user, ci, troubleshooting"
      # cleanup
      case AI.Tools.perform_tool_call(
             "memory_tool",
             %{
               "action" => "forget",
               "scope" => "session",
               "title" => "Topics CSV Pipe"
             },
             AI.Tools.tools()
           ) do
        {:ok, _} -> :ok
        _ -> :ok
      end
    end
  end

  describe "search behavior for session memory" do
    test "session memory search yields scope as string and no crash" do
      mock_project("test_proj")
      mock_conversation()
      assert {:ok, _} = Elixir.Memory.init()

      assert {:ok, _} =
               AI.Tools.perform_tool_call(
                 "memory_tool",
                 %{
                   "action" => "remember",
                   "scope" => "session",
                   "title" => "Search Scope Test",
                   "content" => "search content"
                 },
                 AI.Tools.tools()
               )

      assert {:ok, result} =
               AI.Tools.perform_tool_call(
                 "memory_tool",
                 %{"action" => "recall", "what" => "Search Scope Test"},
                 AI.Tools.tools()
               )

      assert result =~ "\"scope\":\"session\""
    end

    test "Atom.to_string raises ArgumentError on string scope" do
      assert_raise ArgumentError, fn -> apply(Atom, :to_string, ["session"]) end
    end
  end
end
