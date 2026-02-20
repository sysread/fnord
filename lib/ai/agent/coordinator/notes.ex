defmodule AI.Agent.Coordinator.Notes do
  @moduledoc """
  Notes-specific behaviors for AI.Agent.Coordinator, including generating
  messages related to note-taking and management.
  """

  @typep t :: AI.Agent.Coordinator.t()
  @type state :: AI.Agent.Coordinator.state()

  @doc """
  When starting a new conversation session, this ingests the user's prompt into
  the notes infrastructure for later processing.
  """
  @spec init(state) :: state
  def init(%{question: question} = state) do
    Services.Notes.ingest_user_msg(question)
    state
  end

  @doc """
  Retrieves relevant notes based on the user's question. It then appends an
  assistant message reflecting on the retrieved notes to the conversation.
  Finally, it updates the state with the retrieved notes for use in subsequent
  steps.
  """
  @spec with_notes(t) :: t
  def with_notes(%{question: question} = state) do
    UI.begin_step("Rehydrating the lore cache")

    notes = Services.Notes.ask(question)
    Services.Notes.consolidate()

    # Append assistant reflection on prior notes
    """
    <think>
    Let's see what I remember about that...
    #{notes}
    </think>
    """
    |> AI.Util.assistant_msg()
    |> Services.Conversation.append_msg(state.conversation_pid)

    # Update state with retrieved notes
    %{state | notes: notes}
  end

  @doc """
  Saves any new notes generated during the conversation. This function is
  intended to be called at the end of a conversation session to ensure that all
  relevant notes are persisted for future reference.
  """
  @spec save(state) :: state
  def save(passthrough) do
    Services.Notes.save()
    passthrough
  end
end
