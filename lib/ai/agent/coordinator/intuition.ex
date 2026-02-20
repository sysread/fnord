defmodule AI.Agent.Coordinator.Intuition do
  @moduledoc """
  Behaviors related to injecting subconscious intution into the coordinator's
  workflow.
  """

  @type t :: AI.Agent.Coordinator.t()

  @spec automatic_thoughts_msg(t) :: t
  def automatic_thoughts_msg(state) do
    UI.begin_step("Cogitating")

    msgs = Services.Conversation.get_messages(state.conversation_pid)

    AI.Agent.Intuition
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{msgs: msgs})
    |> case do
      {:ok, intuition} ->
        UI.report_step("Intuition", UI.italicize(intuition))

        """
        <think>
        #{intuition}
        </think>
        """
        |> AI.Util.assistant_msg()
        |> Services.Conversation.append_msg(state.conversation_pid)

        %{state | intuition: intuition}

      {:error, reason} ->
        UI.error("Derp. Cogitation failed.", inspect(reason))
        state
    end
  end
end
