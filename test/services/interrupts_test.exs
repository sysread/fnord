defmodule Services.Conversation.InterruptsTest do
  use Fnord.TestCase, async: false

  alias Services.Conversation.Interrupts

  setup do
    # Ensure any leftover interrupts for this PID are cleared
    Interrupts.take_all(self())
    :ok
  end

  test "request/2 enqueues a user message and take_all/1 returns it correctly" do
    refute Interrupts.pending?(self())
    Interrupts.request(self(), "hello")
    assert Interrupts.pending?(self())

    [msg] = Interrupts.take_all(self())
    assert %{role: "user", content: "[User Interrupt] hello"} = msg
    refute Interrupts.pending?(self())
  end

  test "take_all/1 returns messages in FIFO order for multiple enqueues" do
    Interrupts.request(self(), "first")
    Interrupts.request(self(), "second")
    Interrupts.request(self(), "third")

    msgs = Interrupts.take_all(self())
    contents = Enum.map(msgs, & &1.content)

    assert contents == [
             "[User Interrupt] first",
             "[User Interrupt] second",
             "[User Interrupt] third"
           ]
  end

  test "pending?/1 returns true when items exist and false after draining" do
    refute Interrupts.pending?(self())
    Interrupts.request(self(), "item")
    assert Interrupts.pending?(self())

    _ = Interrupts.take_all(self())
    refute Interrupts.pending?(self())
  end

  test "queues are isolated per conversation pid" do
    Interrupts.request(self(), "one")

    # Spawn a separate process to simulate another conversation
    pid2 =
      spawn(fn ->
        receive do
        end
      end)

    Interrupts.request(pid2, "two")

    msgs1 = Interrupts.take_all(self())
    msgs2 = Interrupts.take_all(pid2)

    assert [%{content: "[User Interrupt] one"}] =
             Enum.map(msgs1, fn msg -> %{content: msg.content} end)

    assert [%{content: "[User Interrupt] two"}] =
             Enum.map(msgs2, fn msg -> %{content: msg.content} end)
  end
end
