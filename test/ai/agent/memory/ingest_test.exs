defmodule AI.Agent.Memory.IngestTest do
  use Fnord.TestCase, async: false

  test "filters messages and prepends the ingestion system prompt" do
    test_pid = self()

    {:ok, capture} = Agent.start_link(fn -> [] end)

    :meck.new(AI.CompletionAPI, [:no_link, :passthrough, :non_strict])

    :meck.expect(AI.CompletionAPI, :get, fn _model, msgs, _specs, _res_fmt, _web_search? ->
      Agent.update(capture, fn _ -> msgs end)
      send(test_pid, {:seen_msgs, msgs})
      {:ok, :msg, "Learned.", 0}
    end)

    on_exit(fn ->
      :meck.unload(AI.CompletionAPI)

      if Process.alive?(capture) do
        Agent.stop(capture)
      end
    end)

    msgs = [
      AI.Util.system_msg("(developer/system noise that should be dropped)"),
      AI.Util.user_msg("User asks a thing"),
      AI.Util.assistant_msg("<think>secret reasoning</think>"),
      AI.Util.assistant_msg("Visible assistant content"),
      %{
        role: "assistant",
        tool_calls: [%{id: "t1", function: %{name: "memory_tool", arguments: "{}"}}]
      },
      %{role: "tool", content: "tool result", tool_call_id: "t1"}
    ]

    agent = AI.Agent.new(AI.Agent.Memory.Ingest, named?: false)

    assert {:ok, "Learned."} = AI.Agent.get_response(agent, %{messages: msgs})

    assert_receive {:seen_msgs, seen}

    # Should NOT pass through the original system/developer message
    refute Enum.any?(seen, fn
             %{role: "system", content: "(developer/system noise that should be dropped)"} -> true
             _ -> false
           end)

    # Should NOT pass through <think> content
    refute Enum.any?(seen, fn
             %{role: "assistant", content: "<think>secret reasoning</think>"} -> true
             _ -> false
           end)

    # Should keep user messages, visible assistant messages, tool calls, and tool results
    assert Enum.any?(seen, fn
             %{role: "user", content: "User asks a thing"} -> true
             _ -> false
           end)

    assert Enum.any?(seen, fn
             %{role: "assistant", content: "Visible assistant content"} -> true
             _ -> false
           end)

    assert Enum.any?(seen, fn
             %{role: "assistant", tool_calls: _} -> true
             _ -> false
           end)

    assert Enum.any?(seen, fn
             %{role: "tool", content: "tool result"} -> true
             _ -> false
           end)

    # Ensure the ingestion system prompt is present
    assert Enum.any?(seen, fn
             %{role: role, content: content}
             when role in ["system", "developer"] and is_binary(content) ->
               String.contains?(content, "You are the Long Term Memory Agent")

             _ ->
               false
           end)
  end
end
