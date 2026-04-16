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

    args =
      %{msgs: msgs}
      |> put_if(:perception, state.perception)
      |> Map.put(:samskaras, state.samskaras || [])

    AI.Agent.Intuition
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(args)
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

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
