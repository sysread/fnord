defmodule AI.Agent.Coordinator.Memory do
  @moduledoc """
  Functions related to the Coordinator's memory behavior.
  """

  @type t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @memory_recall_limit 3
  @memory_size_limit 1000

  @spec identity_msg(t) :: t
  def identity_msg(%{conversation_pid: conversation_pid} = state) do
    with {:ok, memory} <- Memory.read_me() do
      """
      <think>
      I am a unique individual. Here is what I know about myself:
      #{memory.content}
      </think>
      """
      |> AI.Util.assistant_msg()
      |> Services.Conversation.append_msg(conversation_pid)
    end

    state
  end

  @spec recall_msg(t) :: t
  def recall_msg(state) do
    UI.begin_step("Spooling mnemonics")

    intuition = state |> Map.get(:intuition, "") |> String.trim()
    question = state |> Map.get(:question, "") |> String.trim()

    [intuition, question]
    |> Enum.join("\n")
    |> Memory.search(@memory_recall_limit)
    |> case do
      {:ok, []} ->
        state

      {:ok, results} ->
        now = DateTime.utc_now()

        memories =
          results
          |> Enum.map(fn {mem, _score} ->
            age = Memory.Presentation.age_line(mem, now)
            warning = Memory.Presentation.warning_line(mem, now)

            warning_md =
              if warning do
                "\n_#{warning}_"
              else
                ""
              end

            """
            ## [#{mem.scope}] #{mem.title}
            _#{age}_#{warning_md}
            #{Util.truncate(mem.content, @memory_size_limit)}
            """
          end)
          |> Enum.join("\n\n")

        """
        <think>
        The user's prompt brings to mind some things I wanted to remember.

        #{memories}
        </think>
        """
        |> AI.Util.assistant_msg()
        |> Services.Conversation.append_msg(state.conversation_pid)

        state

      {:error, reason} ->
        UI.error("memory", reason)
        state
    end
  end
end
