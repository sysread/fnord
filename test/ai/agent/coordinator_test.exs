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

  test "acknowledge_interrupts_for_test echoes interrupt and returns state unchanged" do
    # Inject an interrupt into the real queue
    Services.Conversation.Interrupts.request(self(), "foo")

    state = %{conversation: self(), foo: :bar}
    returned = AI.Agent.Coordinator.acknowledge_interrupts_for_test(state)

    # Should return the same state
    assert returned == state

    # UI.info should have been called with the stripped message
    assert_receive {:info, "You (rude)", "foo"}
  end
end
