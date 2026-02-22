defmodule Memory.SessionIndexerE2ETest do
  use Fnord.TestCase, async: false

  test "session indexer processes memories, creates long-term memory, and marks processed session memories" do
    mock_project("si-e2e")

    # Create conversation and two session memories on disk
    conv = Store.Project.Conversation.new()

    {:ok, m1} = Memory.new(:session, "Session One", "First content", ["topic1"])
    {:ok, m2} = Memory.new(:session, "Session Two", "Second content", ["topic2"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [m1, m2]
             })

    # Prepare indexer AI response: add a project memory and mark both session mems processed
    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Merged Sessions"},
        "from" => %{"title" => "Session One"},
        "content" => "Merged: first and second"
      }
    ]

    processed = ["Session One", "Session Two"]

    response = Jason.encode!(%{"actions" => actions, "processed" => processed})

    # Mock AI.Agent.get_response to return the structured JSON
    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

    on_exit(fn -> :meck.unload(AI.Agent) end)

    # Run the session indexer
    # Ensure the MemoryIndexer is available in this test.
    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link([]) do
          {:ok, _} ->
            on_exit(fn ->
              if Process.whereis(Services.MemoryIndexer),
                do: GenServer.stop(Services.MemoryIndexer)
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert :ok = Services.MemoryIndexer.process_sync(conv)

    # Long-term memory should have been created under project scope
    assert {:ok, proj_mem} = Memory.read(:project, "Merged Sessions")
    assert String.contains?(proj_mem.content, "Merged: first and second")

    # Session memories in the conversation file should be marked :analyzed
    assert {:ok, data} = Store.Project.Conversation.read(conv)

    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)

    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session Two", index_status: :analyzed} -> true
             _ -> false
           end)
  end
end
