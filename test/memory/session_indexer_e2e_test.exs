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
    status_updates = %{"Session Two" => "analyzed"}

    response =
      SafeJson.encode!(%{
        "actions" => actions,
        "processed" => processed,
        "status_updates" => status_updates
      })

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
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

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

  test "session indexer rejects invalid target and does not mark the session memory processed" do
    mock_project("si-e2e-invalid-target")

    conv = Store.Project.Conversation.new()
    {:ok, session_mem} = Memory.new(:session, "Session One", "First content", ["topic1"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [session_mem]
             })

    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Me"},
        "from" => %{"title" => "Session One"},
        "content" => "Should be rejected"
      }
    ]

    response = SafeJson.encode!(%{"actions" => actions, "processed" => ["Session One"]})

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

    :meck.new(AI.Tools.LongTermMemory, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Tools.LongTermMemory, :call, fn _args -> {:ok, :unexpected_success} end)

    on_exit(fn ->
      :meck.unload(AI.Agent)
      :meck.unload(AI.Tools.LongTermMemory)
    end)

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
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

    write_calls =
      :meck.history(AI.Tools.LongTermMemory)
      |> Enum.filter(fn
        {_pid, {AI.Tools.LongTermMemory, :call, [%{"action" => "remember"} | _]}, _result} -> true
        _ -> false
      end)

    assert write_calls == []

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
    mock_project("si-e2e-tool-failure")

    conv = Store.Project.Conversation.new()
    {:ok, session_mem} = Memory.new(:session, "Session One", "First content", ["topic1"])

    assert {:ok, _} =
             Store.Project.Conversation.write(conv, %{
               messages: [],
               metadata: %{},
               memory: [session_mem]
             })

    actions = [
      %{
        "action" => "add",
        "target" => %{"scope" => "project", "title" => "Merged Sessions"},
        "from" => %{"title" => "Session One"},
        "content" => "Should fail to save"
      }
    ]

    response = SafeJson.encode!(%{"actions" => actions, "processed" => ["Session One"]})

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

    :meck.new(AI.Tools.LongTermMemory, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Tools.LongTermMemory, :call, fn _args -> {:error, "boom"} end)

    on_exit(fn ->
      :meck.unload(AI.Agent)
      :meck.unload(AI.Tools.LongTermMemory)
    end)

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

    write_calls =
      :meck.history(AI.Tools.LongTermMemory)
      |> Enum.filter(fn
        {_pid, {AI.Tools.LongTermMemory, :call, [%{"action" => "remember"} | _]}, _result} -> true
        _ -> false
      end)

    assert length(write_calls) == 1

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
    mock_project("si-e2e-explicit-from")

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

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

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

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert {:ok, {:ok, %Store.Project.Conversation{}}} =
             Services.MemoryIndexer.process_sync(conv)

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
    mock_project("si-e2e-no-from-processed")

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

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

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

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

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
    mock_project("si-e2e-invalid-processed-title")

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

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

    :meck.new(AI.Tools.LongTermMemory, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Tools.LongTermMemory, :call, fn _args -> {:ok, :unexpected_success} end)

    on_exit(fn ->
      :meck.unload(AI.Agent)
      :meck.unload(AI.Tools.LongTermMemory)
    end)

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert {:ok, {:ok, %Store.Project.Conversation{}}} = Services.MemoryIndexer.process_sync(conv)

    assert {:ok, data} = Store.Project.Conversation.read(conv)

    # Session One was in the payload, so it gets :analyzed regardless of the
    # agent's processed list containing an unknown title.
    assert Enum.any?(data.memory, fn
             %Memory{scope: :session, title: "Session One", index_status: :analyzed} -> true
             _ -> false
           end)
  end

  test "session indexer does not leave session memories in :new after processing (no infinite reprocessing)" do
    mock_project("si-e2e-no-infinite-loop")

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

    :meck.new(AI.Agent, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Agent, :get_response, fn _agent, _opts -> {:ok, response} end)

    :meck.new(AI.Tools.LongTermMemory, [:no_link, :passthrough, :non_strict])
    :meck.expect(AI.Tools.LongTermMemory, :call, fn _args -> {:ok, []} end)

    on_exit(fn ->
      :meck.unload(AI.Agent)
      :meck.unload(AI.Tools.LongTermMemory)
    end)

    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                catch
                  :exit, _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    Services.MemoryIndexer.process_sync(conv)

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
