defmodule AI.Agent.CoordinatorTest do
  use Fnord.TestCase, async: false

  setup do
    # Ensure the interrupt queue server is running
    case Services.Conversation.Interrupts.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Services.Conversation.Interrupts.take_all(self())

    # Capture UI.info calls
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :info, fn name, msg -> send(self(), {:info, name, msg}) end)

    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  test "display of pending interrupts echoes message and clears pending list" do
    # Create a test interrupt message
    interrupt_msg = %{role: "user", content: "[User Interjection] foo"}

    state = %{conversation: self(), pending_interrupts: [interrupt_msg], foo: :bar}
    returned = Services.Conversation.InterruptsDisplay.display_pending_interrupts(state)

    # Should return the state with cleared interrupts
    assert returned.pending_interrupts == []
    assert returned.foo == :bar

    # UI.info should have been called with the stripped message
    assert_receive {:info, "You (rude)", "foo"}
  end
end
