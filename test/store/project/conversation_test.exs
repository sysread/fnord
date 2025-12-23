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
    assert Map.has_key?(tasks_map, 1)
    assert [
      %{id: "t1", data: "d1", outcome: "todo", result: nil},
      %{id: "t2", data: "d2", outcome: "done", result: "ok"}
    ] = tasks_map[1]

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
end
