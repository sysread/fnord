defmodule AI.Agent.Coordinator.Interrupts do
  @moduledoc """
  Functions related to the Coordinator's user-interrupt handling behavior.
  """

  defstruct listener: nil, pending: []

  @type t :: %__MODULE__{
          listener: pid | nil,
          pending: AI.Util.msg_list()
        }

  @type coord :: AI.Agent.Coordinator.t()

  @spec new(pid | nil) :: t
  def new(pid \\ nil), do: %__MODULE__{listener: pid, pending: []}

  @spec init(coord) :: coord
  def init(%{conversation_pid: convo, interrupts: int} = state) do
    # Only start in interactive TTY sessions and only for Coordinator
    cond do
      Map.get(int, :listener) != nil ->
        state

      UI.quiet?() ->
        state

      UI.is_tty?() ->
        task_pid = Task.start(fn -> loop(convo, true) end) |> elem(1)
        Map.put(state, :interrupts, new(task_pid))

      true ->
        state
    end
  end

  @spec pending(coord) :: AI.Util.msg_list()
  def pending(%{interrupts: %{pending: p}}), do: p

  defp loop(convo_pid, show_msg? \\ false) do
    if show_msg? do
      UI.info("""
      Use enter (or ctrl-j) to interrupt and send feedback to the agent.
      NOTE: Interrupts do not interrupt in-flight tool calls or completions.
      """)
    end

    case IO.getn(:stdio, "", 1) do
      "\n" ->
        # If interrupts are blocked (e.g., during finalization), refuse immediately
        if Services.Conversation.Interrupts.blocked?(convo_pid) do
          conv_id = Services.Conversation.get_id(convo_pid)

          UI.warn(
            "Finalizing in progress: interrupts cannot be delivered right now.",
            "Ongoing tool operations may complete. Use `-f #{conv_id}` to follow this conversation and queue a new question."
          )

          loop(convo_pid)
        else
          "What would you like to say? (empty to ignore)"
          |> UI.prompt(optional: true, use_notification_timer: false)
          |> case do
            {:error, _} ->
              :ok

            nil ->
              :ok

            msg when is_binary(msg) ->
              msg
              |> String.trim()
              |> case do
                "" ->
                  :ok

                msg ->
                  Services.Conversation.interrupt(convo_pid, msg)

                  UI.info(
                    "Interrupt handler",
                    "Your message has been queued and will be delivered after the on-going API call completes."
                  )
              end

            _ ->
              :ok
          end

          loop(convo_pid, true)
        end

      # Ignore any other input
      _ ->
        loop(convo_pid)
    end
  end
end
