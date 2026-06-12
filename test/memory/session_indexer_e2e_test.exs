defmodule Memory.SessionIndexerE2ETest do
  use Fnord.TestCase, async: true

  # These tests drive Services.MemoryIndexer.process_sync against the REAL
  # AI.Tools.LongTermMemory tool; only the indexer agent itself is canned
  # (via canned_agent). Memory writes land in the mock project's on-disk
  # store, so assertions read the store directly instead of counting mock
  # calls.
  #
  # The memory storage directories are created up front: in production
  # Memory.init (called from Cmd.Ask) creates them before the indexer can
  # run, and the tool's recall candidate listing hard-matches {:ok, _} from
  # Memory.Global.list/Memory.Project.list, which error on a missing
  # directory.
  defp setup_indexer(project_name) do
    mock_project(project_name)
    {:ok, project} = Store.get_project(project_name)
    File.mkdir_p!(Path.join(project.store_path, "memory"))
    File.mkdir_p!(Path.join(Store.store_home(), "memory"))
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)
    # The indexer GenServer calls MockIndexer (embeddings for recall
    # candidates) and the canned agent dispatcher; grant it this test's
    # private-mode Mox ownership like any other ad-hoc tree service.
    allow_service_mocks(self())
    project
  end

  defp project_memory_files(project) do
    project.store_path
    |> Path.join("memory")
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
  end

  test "session indexer processes memories, creates long-term memory, and marks processed session memories" do
    project = setup_indexer("si-e2e")

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
    status_updates = %{"Session Two" => "analyzed"}

    response =
      SafeJson.encode!(%{
        "actions" => actions,
        "processed" => processed,
        "status_updates" => status_updates
      })

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

    # The real tool's remember action writes the project memory through
    # Memory.save before process_sync returns, so the file is present
    # immediately - no polling window needed.
    slug = Memory.title_to_slug("Merged Sessions")
    path = Path.join([project.store_path, "memory", "#{slug}.json"])
    assert File.exists?(path), "expected project memory file #{path} to be created"

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

  test "session indexer rejects invalid target and does not mark the session memory processed" do
    project = setup_indexer("si-e2e-invalid-target")

    conv = Store.Project.Conversation.new()
    {:ok, session_mem} = Memory.new(:session, "Session One", "First content", ["topic1"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [session_mem]
             })

    # "Me" is reserved to the global scope by Memory.ScopePolicy, so a
    # project-scoped target fails the indexer's response validation before
    # any action is applied.
    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Me"},
        "from" => %{"title" => "Session One"},
        "content" => "Should be rejected"
      }
    ]

    response = SafeJson.encode!(%{"actions" => actions, "processed" => ["Session One"]})

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert :ok = Services.MemoryIndexer.process_sync(conv)

    # Validation rejected the whole response, so no memory write reached the
    # project store.
    assert project_memory_files(project) == []

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: status}
             when status in [:new, nil, :pending] ->
               true

             _ ->
               false
           end)
  end

  test "session indexer marks session memory analyzed even when long-term tool fails" do
    project = setup_indexer("si-e2e-tool-failure")

    conv = Store.Project.Conversation.new()
    {:ok, session_mem} = Memory.new(:session, "Session One", "First content", ["topic1"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [session_mem]
             })

    # A tab in the title passes the indexer's target validation (ScopePolicy
    # checks scope eligibility, not characters) but fails Memory.new's title
    # validation inside the real tool, which returns {:error, "invalid_title"}.
    # Pure-data failure injection for the tool-failure path.
    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Bad\tTitle"},
        "from" => %{"title" => "Session One"},
        "content" => "Should fail to save"
      }
    ]

    response = SafeJson.encode!(%{"actions" => actions, "processed" => ["Session One"]})

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

    # The tool failed, so nothing was written to the project store.
    assert project_memory_files(project) == []

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # The agent returned a valid response so the memory is marked :analyzed
    # even though the tool call failed. Re-processing would produce the same
    # agent decision, so looping on a persistent tool failure is worse than
    # marking it done and moving on.
    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)
  end

  test "session indexer marks all payload memories as analyzed after valid response" do
    project = setup_indexer("si-e2e-explicit-from")

    conv = Store.Project.Conversation.new()

    {:ok, m1} = Memory.new(:session, "Session One", "First content", ["topic1"])
    {:ok, m2} = Memory.new(:session, "Session Two", "Second content", ["topic2"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [m1, m2]
             })

    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Merged Sessions"},
        "from" => %{"title" => "Session One"},
        "content" => "Only first session incorporated"
      }
    ]

    response = SafeJson.encode!(%{"actions" => actions, "processed" => []})

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

    # The real tool persisted the new project memory.
    assert project_memory_files(project) == [
             "#{Memory.title_to_slug("Merged Sessions")}.json"
           ]

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # Both memories were in the payload, so both are marked regardless of
    # whether they appeared in the agent's "from" or "processed" fields.
    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)

    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session Two", index_status: :analyzed} -> true
             _ -> false
           end)
  end

  test "session indexer marks all payload memories analyzed and applies status_updates on top" do
    setup_indexer("si-e2e-no-from-processed")

    conv = Store.Project.Conversation.new()

    {:ok, m1} = Memory.new(:session, "Session One", "First content", ["topic1"])
    {:ok, m2} = Memory.new(:session, "Session Two", "Second content", ["topic2"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [m1, m2]
             })

    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Merged Sessions"},
        "content" => "Generalized summary without explicit source"
      }
    ]

    processed = ["Session One", "Session Two"]
    status_updates = %{"Session Two" => "analyzed"}

    response =
      SafeJson.encode!(%{
        "actions" => actions,
        "processed" => processed,
        "status_updates" => status_updates
      })

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # Both memories were in the payload, so both get baseline :analyzed.
    # Session Two additionally has a status_update to :analyzed (no-op on top
    # of the baseline, but confirms status_updates still apply).
    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)

    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session Two", index_status: :analyzed} -> true
             _ -> false
           end)
  end

  test "session indexer marks payload memory analyzed even when agent processed list contains unknown titles" do
    project = setup_indexer("si-e2e-invalid-processed-title")

    conv = Store.Project.Conversation.new()
    {:ok, session_mem} = Memory.new(:session, "Session One", "First content", ["topic1"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [session_mem]
             })

    response =
      SafeJson.encode!(%{
        "actions" => [],
        "processed" => ["Missing Session"]
      })

    canned_agent(fn _impl, _args -> {:ok, response} end)

    assert {:ok, {:ok, %Store.Project.Conversation{}}} = Services.MemoryIndexer.process_sync(conv)

    # No actions means no long-term memory writes.
    assert project_memory_files(project) == []

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # Session One was in the payload, so it gets :analyzed regardless of the
    # agent's processed list containing an unknown title.
    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)
  end

  test "session indexer does not leave session memories in :new after processing (no infinite reprocessing)" do
    project = setup_indexer("si-e2e-no-infinite-loop")

    conv = Store.Project.Conversation.new()

    {:ok, m1} = Memory.new(:session, "Alpha Memory", "Content alpha", ["topic1"])
    {:ok, m2} = Memory.new(:session, "Beta Memory", "Content beta", ["topic2"])
    {:ok, m3} = Memory.new(:session, "Gamma Memory", "Content gamma", ["topic3"])
    {:ok, m4} = Memory.new(:session, "Delta Memory", "Content delta", ["topic4"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [m1, m2, m3, m4]
             })

    # Agent responds with no actions but marks all session memories via
    # processed + status_updates (the replace/delete path - no "from" fields).
    # This is the path most likely to leave memories unmarked and cause
    # the indexer to reprocess the same conversation indefinitely.
    processed = ["Alpha Memory", "Beta Memory", "Gamma Memory", "Delta Memory"]

    status_updates = %{
      "Alpha Memory" => "analyzed",
      "Beta Memory" => "analyzed",
      "Gamma Memory" => "incorporated",
      "Delta Memory" => "incorporated"
    }

    response =
      SafeJson.encode!(%{
        "actions" => [],
        "processed" => processed,
        "status_updates" => status_updates
      })

    canned_agent(fn _impl, _args -> {:ok, response} end)

    Services.MemoryIndexer.process_sync(conv)

    # No actions means no long-term memory writes.
    assert project_memory_files(project) == []

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # No session memory should remain :new or nil after processing.
    # If any do, the indexer would loop forever on the same conversation.
    stuck =
      Enum.filter(data.memory, fn
        %Memory{scope: :session, index_status: status} when status in [nil, :new] -> true
        _ -> false
      end)

    assert stuck == [],
           "Session memories left unprocessed (would cause infinite reprocessing): #{inspect(Enum.map(stuck, & &1.title))}"
  end
end
