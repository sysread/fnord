defmodule Store.Project.ConversationTest do
  use ExUnit.Case, async: true
  use TestUtil

  alias Store.Project.Conversation

  setup do: set_config(workers: 1, quiet: true)

  setup do
    {:ok, project: mock_project("blarg")}
  end

  test "new/2", ctx do
    id = "DEADBEEF"

    expected_path =
      ctx.project.store_path
      |> Path.join("conversations/#{id}.json")

    convo = Conversation.new(id, ctx.project)

    assert convo.project == ctx.project
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

    assert convo.project == ctx.project
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

    assert convo.project == ctx.project
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
    assert {:ok, convo} = Conversation.write(convo, messages)

    # File now exists
    assert Conversation.exists?(convo)

    # Read it back
    assert {:ok, ts, ^messages} = Conversation.read(convo)
    assert ^ts = Conversation.timestamp(convo)
    assert {:ok, "Hello, I am User."} = Conversation.question(convo)
  end
end