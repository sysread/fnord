defmodule AI.Agent.Coordinator.Samskara do
  @moduledoc """
  Coordinator bootstrap hooks for samskaras: derive the current perception,
  fire relevant past samskaras, stash both on state, and inject a preamble
  system message telling the coordinator how to weight them.
  """

  alias Store.Project.Samskara.Record

  @type t :: AI.Agent.Coordinator.t()

  @preamble_header """
  # Samskara preamble

  Samskaras are embedded records of significant past user reactions in this
  project — corrections, approvals, pivots, and the like. The ones below were
  retrieved by similarity to the current turn's perception. They are hints,
  not commands: they temper your instincts with what the user has historically
  cared about. If a samskara contradicts the user's current explicit request,
  the current request wins.
  """

  @spec prepare(t) :: t
  def prepare(state) do
    msgs = Services.Conversation.get_messages(state.conversation_pid)

    observe_turn(state, msgs)

    AI.Agent.Perception
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{msgs: msgs})
    |> case do
      {:ok, %AI.Agent.Perception.Result{} = perception} ->
        firings = fire(state, perception)
        %{state | perception: perception, samskaras: firings}

      {:error, reason} ->
        UI.warn("samskara: perception failed", inspect(reason))
        %{state | perception: nil, samskaras: []}
    end
  end

  defp observe_turn(%{followup?: false}, _msgs), do: :ok

  defp observe_turn(%{question: question, project: project_name}, msgs)
       when is_binary(question) and question != "" do
    case last_assistant_content(msgs) do
      nil ->
        :ok

      prev when is_binary(prev) ->
        if Process.whereis(Services.SamskaraReactor) do
          Services.SamskaraReactor.observe_turn(%{
            prev_assistant: prev,
            user_message: question,
            project: project_name
          })
        end

        :ok
    end
  end

  defp observe_turn(_state, _msgs), do: :ok

  defp last_assistant_content(msgs) do
    msgs
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "assistant", content: c} when is_binary(c) and c != "" -> c
      _ -> nil
    end)
  end

  @spec preamble_msg(t) :: t
  def preamble_msg(%{samskaras: []} = state), do: state

  def preamble_msg(%{conversation_pid: pid, samskaras: records} = state) do
    records
    |> build_preamble()
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(pid)

    state
  end

  @spec build_preamble([Record.t()]) :: binary
  def build_preamble([]), do: @preamble_header

  def build_preamble(records) when is_list(records) do
    bullets =
      records
      |> Enum.map(fn r ->
        lessons =
          case r.lessons do
            [] -> ""
            list -> "\n  - lessons: " <> Enum.join(list, "; ")
          end

        "- [#{r.reaction}] #{r.gist}#{lessons}"
      end)
      |> Enum.join("\n")

    """
    #{@preamble_header}

    #{bullets}
    """
    |> String.trim_trailing()
  end

  defp fire(state, perception) do
    case Store.get_project(state.project) do
      {:ok, project} ->
        AI.Samskara.Firing.records_for_perception(project, perception)

      _ ->
        []
    end
  end
end
