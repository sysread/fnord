defmodule AI.Agent.Code.PatcherTest do
  use Fnord.TestCase, async: false

  # -------------------------------------------------------------------------
  # These tests verify the Patcher's retry-with-feedback and context
  # passthrough behaviors. The Patcher is an AI agent that applies natural
  # language change instructions to files by producing hash-anchored patches.
  # We mock the AI completion layer to control responses and inspect what
  # messages the Patcher sends on first attempt vs retry.
  # -------------------------------------------------------------------------

  setup do
    project = mock_project("patcher-test")

    :meck.new(AI.Completion, [:no_link, :non_strict, :passthrough])
    :meck.new(AI.Tools, [:no_link, :non_strict, :passthrough])

    on_exit(fn ->
      :meck.unload(AI.Completion)
      :meck.unload(AI.Tools)
    end)

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

  # Helper: extract user messages from a keyword list of completion args.
  # Messages use atom keys (e.g. %{role: "user", content: "..."}).
  defp user_messages(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> Enum.filter(fn msg -> msg[:role] == "user" end)
  end

  # Helper: extract assistant messages from a keyword list of completion args
  defp assistant_messages(opts) do
    opts
    |> Keyword.get(:messages, [])
    |> Enum.filter(fn msg -> msg[:role] == "assistant" end)
  end

  describe "retry with error feedback" do
    test "retry includes previous failure in messages", %{project: project} do
      file_content = "line one\nline two\nline three\n"
      file = mock_source_file(project, "retry.txt", file_content)

      :meck.expect(AI.Tools, :get_file_contents, fn _path ->
        {:ok, file_content}
      end)

      # Track calls to inspect messages on each attempt
      call_count = :counters.new(1, [:atomics])

      :meck.expect(AI.Completion, :get, fn opts ->
        attempt = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, attempt)

        if attempt == 1 do
          # First attempt: return an error response from the LLM
          {:ok, %{response: error_patch_response("I can't figure out this change")}}
        else
          # Second attempt: verify error feedback is in messages, then succeed
          messages = Keyword.get(opts, :messages, [])
          assert length(messages) == 5

          assistant_msgs = assistant_messages(opts)
          assert length(assistant_msgs) == 1
          assert assistant_msgs |> hd() |> Map.get(:content) =~ "I can't figure out"

          user_msgs = user_messages(opts)
          assert length(user_msgs) == 2
          error_feedback = List.last(user_msgs)
          assert error_feedback[:content] =~ "Your previous patch attempt failed"
          assert error_feedback[:content] =~ "I can't figure out this change"

          # Return a valid patch
          h1 = "1:" <> Util.line_hash("line one")
          h2 = "2:" <> Util.line_hash("line two")

          {:ok,
           %{
             response:
               patch_response(
                 [h1, h2],
                 "line one\nline two",
                 "LINE ONE\nLINE TWO"
               )
           }}
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
      assert :counters.get(call_count, 1) == 2
    end

    test "first attempt has only 2 messages", %{project: project} do
      file_content = "hello world\n"
      file = mock_source_file(project, "first.txt", file_content)

      :meck.expect(AI.Tools, :get_file_contents, fn _path ->
        {:ok, file_content}
      end)

      :meck.expect(AI.Completion, :get, fn opts ->
        messages = Keyword.get(opts, :messages, [])
        assert length(messages) == 3

        h1 = "1:" <> Util.line_hash("hello world")

        {:ok,
         %{
           response:
             patch_response(
               [h1],
               "hello world",
               "HELLO WORLD"
             )
         }}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Uppercase everything"]
               })
    end
  end

  describe "context passthrough" do
    test "context appears in user message when provided", %{project: project} do
      file_content = "original\n"
      file = mock_source_file(project, "context.txt", file_content)

      :meck.expect(AI.Tools, :get_file_contents, fn _path ->
        {:ok, file_content}
      end)

      :meck.expect(AI.Completion, :get, fn opts ->
        user_msgs = user_messages(opts)
        first_user_msg = hd(user_msgs)
        assert first_user_msg[:content] =~ "Background context from the coordinating agent:"
        assert first_user_msg[:content] =~ "Use snake_case for all function names"

        h1 = "1:" <> Util.line_hash("original")

        {:ok,
         %{
           response:
             patch_response(
               [h1],
               "original",
               "modified"
             )
         }}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Change original to modified"],
                 context: "Use snake_case for all function names"
               })
    end

    test "no context section when context is nil", %{project: project} do
      file_content = "original\n"
      file = mock_source_file(project, "nocontext.txt", file_content)

      :meck.expect(AI.Tools, :get_file_contents, fn _path ->
        {:ok, file_content}
      end)

      :meck.expect(AI.Completion, :get, fn opts ->
        user_msgs = user_messages(opts)
        first_user_msg = hd(user_msgs)
        refute first_user_msg[:content] =~ "Background context"

        h1 = "1:" <> Util.line_hash("original")

        {:ok,
         %{
           response:
             patch_response(
               [h1],
               "original",
               "modified"
             )
         }}
      end)

      agent = AI.Agent.new(AI.Agent.Code.Patcher)

      assert {:ok, _result} =
               AI.Agent.get_response(agent, %{
                 file: file,
                 changes: ["Change original to modified"]
               })
    end
  end
end
