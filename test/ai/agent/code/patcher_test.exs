defmodule AI.Agent.Code.PatcherTest do
  use Fnord.TestCase, async: true

  # -------------------------------------------------------------------------
  # These tests verify the Patcher's retry-with-feedback and context
  # passthrough behaviors. The Patcher is an AI agent that applies natural
  # language change instructions to files by producing hash-anchored patches.
  # Canned completions control the LLM responses while the real agent runs:
  # file reads go through the real AI.Tools.get_file_contents (the file
  # exists in the mock project), and each completion's messages are captured
  # at the completion-API boundary and asserted in the test process.
  # -------------------------------------------------------------------------

  setup do
    project = mock_project("patcher-test")
    {:ok, project: project}
  end

  # Helper: build a valid JSON patch response that the Patcher expects.
  # The hashes and old_string must match the file content for patch_by_hashes
  # to succeed.
  defp patch_response(hashes, old_string, new_string) do
    SafeJson.encode!(%{
      "error" => "",
      "hashes" => hashes,
      "old_string" => old_string,
      "new_string" => new_string
    })
  end

  # Helper: build a failing JSON patch response
  defp error_patch_response(msg) do
    SafeJson.encode!(%{
      "error" => msg,
      "hashes" => [],
      "old_string" => "",
      "new_string" => ""
    })
  end

  # Helpers: extract user/assistant messages from a captured messages list.
  defp user_messages(msgs) do
    Enum.filter(msgs, &match?(%AI.Message.User{}, &1))
  end

  defp assistant_messages(msgs) do
    Enum.filter(msgs, &match?(%AI.Message.Assistant{}, &1))
  end

  describe "retry with error feedback" do
    test "retry includes previous failure in messages", %{project: project} do
      file_content = "line one\nline two\nline three\n"
      file = mock_source_file(project, "retry.txt", file_content)

      h1 = "1:" <> Util.line_hash("line one")
      h2 = "2:" <> Util.line_hash("line two")

      test_pid = self()

      # First attempt: the LLM reports it cannot make the change. The retry
      # is recognized by the error feedback the Patcher must thread back into
      # the conversation; it gets a valid patch.
      canned_completion(fn msgs ->
        send(test_pid, {:completion_msgs, msgs})

        retry? =
          msgs
          |> user_messages()
          |> Enum.any?(&(&1.content =~ "Your previous patch attempt failed"))

        if retry? do
          {:ok, :msg, patch_response([h1, h2], "line one\nline two", "LINE ONE\nLINE TWO"), 0}
        else
          {:ok, :msg, error_patch_response("I can't figure out this change"), 0}
        end
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Uppercase the first two lines"]
               })

      assert result =~ "LINE ONE"
      assert result =~ "LINE TWO"

      # Exactly two attempts
      assert_received {:completion_msgs, _first_attempt}
      assert_received {:completion_msgs, retry_msgs}
      refute_received {:completion_msgs, _}

      # The retry carries the full first exchange plus the error feedback.
      # (Counts are at the completion-API boundary, where the loop has
      # prepended one agent-name message to the Patcher's own messages.)
      assert length(retry_msgs) == 6

      assistant_msgs = assistant_messages(retry_msgs)
      assert length(assistant_msgs) == 1
      assert assistant_msgs |> hd() |> Map.get(:content) =~ "I can't figure out"

      user_msgs = user_messages(retry_msgs)
      assert length(user_msgs) == 2
      error_feedback = List.last(user_msgs)
      assert error_feedback.content =~ "Your previous patch attempt failed"
      assert error_feedback.content =~ "I can't figure out this change"
    end

    test "first attempt has only the initial messages", %{project: project} do
      file_content = "hello world\n"
      file = mock_source_file(project, "first.txt", file_content)

      h1 = "1:" <> Util.line_hash("hello world")

      test_pid = self()

      canned_completion(fn msgs ->
        send(test_pid, {:completion_msgs, msgs})
        {:ok, :msg, patch_response([h1], "hello world", "HELLO WORLD"), 0}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Uppercase everything"]
               })

      # The loop's agent-name message plus the Patcher's system and task
      # messages - nothing else on a first attempt.
      assert_received {:completion_msgs, msgs}
      assert length(msgs) == 4
    end
  end

  describe "context passthrough" do
    test "context appears in user message when provided", %{project: project} do
      file_content = "original\n"
      file = mock_source_file(project, "context.txt", file_content)

      h1 = "1:" <> Util.line_hash("original")

      test_pid = self()

      canned_completion(fn msgs ->
        send(test_pid, {:completion_msgs, msgs})
        {:ok, :msg, patch_response([h1], "original", "modified"), 0}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Change original to modified"],
                 context: "Use snake_case for all function names"
               })

      assert_received {:completion_msgs, msgs}
      first_user_msg = msgs |> user_messages() |> hd()
      assert first_user_msg.content =~ "Background context from the coordinating agent:"
      assert first_user_msg.content =~ "Use snake_case for all function names"
    end

    test "no context section when context is nil", %{project: project} do
      file_content = "original\n"
      file = mock_source_file(project, "nocontext.txt", file_content)

      h1 = "1:" <> Util.line_hash("original")

      test_pid = self()

      canned_completion(fn msgs ->
        send(test_pid, {:completion_msgs, msgs})
        {:ok, :msg, patch_response([h1], "original", "modified"), 0}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Change original to modified"]
               })

      assert_received {:completion_msgs, msgs}
      first_user_msg = msgs |> user_messages() |> hd()
      refute first_user_msg.content =~ "Background context"
    end
  end
end
