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

    # Also stub the long_term memory tool to perform an actual project save
    # during the test. This avoids timing/race issues with on-disk writes and
    # keeps the test deterministic.
    :meck.new(AI.Tools.LongTermMemory, [:no_link, :passthrough, :non_strict])

    :meck.expect(AI.Tools.LongTermMemory, :call, fn
      %{"action" => "remember", "scope" => scope, "title" => title, "content" => content} ->
        scope_atom = String.to_atom(scope)

        case Memory.new(scope_atom, title, content, []) do
          {:ok, mem} ->
            case Memory.save(mem) do
              {:ok, saved} -> {:ok, saved}
              :ok -> {:ok, mem}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "unsupported"}
    end)

    on_exit(fn ->
      :meck.unload(AI.Agent)
      :meck.unload(AI.Tools.LongTermMemory)
    end)

    # Run the session indexer
    # Ensure the MemoryIndexer is available in this test.
    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link([]) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                rescue
                  _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert :ok = Services.MemoryIndexer.process_sync(conv)

    # Long-term memory should have been created under project scope. Allow a
    # short, bounded polling window to account for any scheduling jitter when
    # the MemoryIndexer writes the project memory.
    # Check directly on-disk for the project memory file to avoid relying on
    # in-process project selection semantics during this test.
    {:ok, project} = Store.get_project("si-e2e")
    slug = Memory.title_to_slug("Merged Sessions")
    path = Path.join([project.store_path, "memory", "#{slug}.json"])

    # Poll for the file to appear (bounded)
    found =
      Enum.reduce_while(1..40, false, fn _i, _acc ->
        if File.exists?(path) do
          {:halt, true}
        else
          :timer.sleep(100)
          {:cont, false}
        end
      end)

    assert found, "expected project memory file #{path} to be created"

    # Read and validate content
    {:ok, json} = File.read(path)
    {:ok, mem} = Memory.unmarshal(json)
    assert String.contains?(mem.content, "Merged: first and second")

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
