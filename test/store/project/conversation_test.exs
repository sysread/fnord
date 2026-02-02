defmodule Store.Project.ConversationTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Conversation

  setup do
    {:ok, project: mock_project("blarg")}
  end

  test "new/2", ctx do
    id = "DEADBEEF"

    expected_path =
      ctx.project.store_path
      |> Path.join("conversations/#{id}.json")

    convo = Conversation.new(id, ctx.project)

    assert convo.project_home == ctx.project.store_path
    assert convo.store_path == expected_path
    assert convo.id == id
    refute Conversation.exists?(convo)
    assert 0 = Conversation.timestamp(convo)
  end

  test "new/1", ctx do
    id = "DEADBEEF"

    expected_path =
      ctx.project.store_path
      |> Path.join("conversations/#{id}.json")

    convo = Conversation.new(id)

    assert convo.project_home == ctx.project.store_path
    assert convo.store_path == expected_path
    assert convo.id == id
    refute Conversation.exists?(convo)
    assert 0 = Conversation.timestamp(convo)
  end

  test "new/0", ctx do
    convo = Conversation.new()

    expected_path =
      ctx.project.store_path
      |> Path.join("conversations/#{convo.id}.json")

    assert convo.project_home == ctx.project.store_path
    assert convo.store_path == expected_path
    refute is_nil(convo.id)
    refute Conversation.exists?(convo)
    assert 0 = Conversation.timestamp(convo)
  end

  test "write/2 <=> read/1" do
    messages = [
      AI.Util.system_msg("You are a helpful assistant."),
      AI.Util.user_msg("Hello, I am User."),
      AI.Util.assistant_msg("That is lovely. I am Assistant.")
    ]

    convo = Conversation.new()

    # File does not yet exist
    refute Conversation.exists?(convo)
    assert 0 = Conversation.timestamp(convo)
    assert {:error, :enoent} = Conversation.read(convo)

    # Save it to disk
    assert {:ok, convo} = Conversation.write(convo, %{messages: messages})

    # File now exists
    assert Conversation.exists?(convo)

    # Read it back
    assert {:ok,
            %{
              timestamp: ts,
              messages: ^messages,
              memory: []
            }} = Conversation.read(convo)

    assert ^ts = Conversation.timestamp(convo)
    assert {:ok, "Hello, I am User."} = Conversation.question(convo)
  end

  test "tasks round-trip through write/2 and read/1" do
    tasks = %{
      1 => [
        Services.Task.new_task("t1", "d1"),
        Services.Task.new_task("t2", "d2", outcome: :done, result: "ok")
      ]
    }

    convo = Conversation.new()

    assert {:ok, convo} = Conversation.write(convo, %{messages: [], tasks: tasks})

    assert {:ok, %{messages: [], memory: [], tasks: tasks_map}} = Conversation.read(convo)
    # Keys are preserved as string slugs with description:nil for legacy lists
    assert Map.has_key?(tasks_map, "1")
    assert %{tasks: task_list, description: nil} = tasks_map["1"]

    assert [
             %{id: "t1", data: "d1", outcome: :todo, result: nil},
             %{id: "t2", data: "d2", outcome: :done, result: "ok"}
           ] = task_list
  end

  test "read/1 legacy tasks shape loads tasks with string list_id and nil description", ctx do
    # Prepare a legacy JSON file with numeric keys in "tasks"
    id = "legacy"
    convo = Conversation.new(id, ctx.project)
    File.mkdir_p!(Path.dirname(convo.store_path))

    legacy_tasks = [
      %{"id" => "t1", "data" => "d1", "outcome" => "todo", "result" => nil}
    ]

    legacy_data = %{
      "messages" => [],
      "metadata" => %{},
      "memory" => [],
      "tasks" => %{"123" => legacy_tasks}
    }

    timestamp = 42
    File.write!(convo.store_path, "#{timestamp}:" <> Jason.encode!(legacy_data))

    assert {:ok, %{tasks: tasks_map}} = Conversation.read(convo)
    assert Map.has_key?(tasks_map, "123")
    assert %{tasks: tasks, description: nil} = tasks_map["123"]
    assert [%{id: "t1", data: "d1", outcome: :todo, result: nil}] = tasks
  end

  test "read/1 new tasks shape loads tasks with description", ctx do
    # Prepare a new-format JSON file with tasks map and description per list
    id = "newshape"
    convo = Conversation.new(id, ctx.project)
    File.mkdir_p!(Path.dirname(convo.store_path))

    new_tasks = [
      %{"id" => "a1", "data" => "info", "outcome" => "done", "result" => "ok"}
    ]

    new_data = %{
      "messages" => [],
      "metadata" => %{},
      "memory" => [],
      "tasks" => %{
        "s1" => %{"tasks" => new_tasks, "description" => "Sample List Description"}
      }
    }

    timestamp = 123
    File.write!(convo.store_path, "#{timestamp}:" <> Jason.encode!(new_data))

    assert {:ok, %{tasks: tasks_map}} = Conversation.read(convo)
    # Expect list key preserved and description loaded
    assert Map.has_key?(tasks_map, "s1")
    assert %{tasks: task_list, description: "Sample List Description"} = tasks_map["s1"]
    assert [%{id: "a1", data: "info", outcome: :done, result: "ok"}] = task_list
  end

  test "list/1 returns conversations in descending timestamp order", ctx do
    id1 = "one"
    id2 = "two"

    ts1 = 1_000
    ts2 = 2_000

    conv1 = Conversation.new(id1, ctx.project)
    conv2 = Conversation.new(id2, ctx.project)

    File.mkdir_p!(Path.dirname(conv1.store_path))

    File.write!(conv1.store_path, "#{ts1}:{\"messages\":[]}")
    File.write!(conv2.store_path, "#{ts2}:{\"messages\":[]}")

    assert [%Conversation{id: ^id1}, %Conversation{id: ^id2}] =
             Conversation.list(ctx.project.store_path)
  end

  test "fork/1 creates a new conversation with a distinct id and identical messages" do
    messages = [
      AI.Util.system_msg("You are a helpful assistant."),
      AI.Util.user_msg("What's up?"),
      AI.Util.assistant_msg("Not much, you?")
    ]

    orig = Conversation.new()
    assert {:ok, orig} = Conversation.write(orig, %{messages: messages})

    assert {:ok, forked} = Conversation.fork(orig)
    assert forked.id != orig.id
    assert Conversation.exists?(forked)

    # Messages are identical after fork
    assert {:ok, %{messages: ^messages}} = Conversation.read(forked)
    assert {:ok, %{messages: ^messages}} = Conversation.read(orig)

    # Forked conversation is independent of the original
    new_msgs = messages ++ [AI.Util.user_msg("Forked world!")]
    assert {:ok, forked} = Conversation.write(forked, %{messages: new_msgs})
    assert {:ok, %{messages: ^new_msgs}} = Conversation.read(forked)
    assert {:ok, %{messages: ^messages}} = Conversation.read(orig)
  end

  test "roundtrip persistence preserves task list metadata (description)" do
    convo = Conversation.new()

    task1 = Services.Task.new_task("t1", "data1", outcome: :todo)
    task2 = Services.Task.new_task("t2", "data2", outcome: :done, result: "ok")

    tasks_with_desc = %{
      "my-list" => %{
        tasks: [task1, task2],
        description: "My important list"
      }
    }

    # Write with description
    assert {:ok, convo} = Conversation.write(convo, %{messages: [], tasks: tasks_with_desc})

    # Read back and verify structure is preserved
    assert {:ok, %{tasks: read_tasks}} = Conversation.read(convo)
    assert Map.has_key?(read_tasks, "my-list")
    assert %{tasks: tasks_list, description: "My important list"} = read_tasks["my-list"]
    assert length(tasks_list) == 2
    assert [%{id: "t1", outcome: :todo}, %{id: "t2", outcome: :done, result: "ok"}] = tasks_list
  end

  test "roundtrip preserves nil description for task lists" do
    convo = Conversation.new()

    task1 = Services.Task.new_task("t1", "data1")

    tasks_no_desc = %{
      "list-no-desc" => %{
        tasks: [task1],
        description: nil
      }
    }

    assert {:ok, convo} = Conversation.write(convo, %{messages: [], tasks: tasks_no_desc})
    assert {:ok, %{tasks: read_tasks}} = Conversation.read(convo)
    assert %{tasks: [%{id: "t1"}], description: nil} = read_tasks["list-no-desc"]
  end
end
