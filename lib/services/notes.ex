defmodule Services.Notes do
  use GenServer

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load existing research notes from persistent storage. The project must be set
  from the --project command line option or CWD.
  """
  @spec load_notes() :: :ok | {:error, any}
  def load_notes() do
    GenServer.cast(__MODULE__, :load_notes)
  end

  @doc """
  Uses an AI model to answer a question about the existing research notes. The
  question should be a concise request for information about the project, such
  as "What is the purpose of this project?" or "What languages and technologies
  are used in this project?". The AI model will analyze the existing notes and
  return a concise answer.
  """
  @spec ask(binary) :: binary
  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question}, :infinity)
  end

  @doc """
  Uses an AI model to analyze the user's message and extract insights about
  their coding preferences, learning style, personality, and other relevant
  traits. The insights are stored in the server's state and can be consolidated
  later.
  """
  @spec ingest_user_msg(binary) :: :ok
  def ingest_user_msg(msg_text) do
    GenServer.cast(__MODULE__, {:ingest_user_msg, msg_text})
  end

  @doc """
  Uses an AI model to analyze the result of a tool call and extract facts about
  the project. The facts are stored in the server's state and can be
  consolidated later.
  """
  @spec ingest_research(binary, binary, any) :: :ok
  def ingest_research(func, args_json, result) do
    GenServer.cast(__MODULE__, {:ingest_research, func, args_json, result})
  end

  @doc """
  Consolidates all newly extracted facts and user insights into the existing
  research notes. This uses an AI model to reorganize and consolidate the notes
  according to specified guidelines. The consolidated notes are saved to
  persistent storage.

  Currently, consolidation generally happens at the beginning of a new research
  session (from `AI.Agent.Coordinator`).
  """
  @spec consolidate() :: :ok
  def consolidate() do
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc """
  Waits for the server to complete all operations before returning. This is
  useful to ensure that all notes have been saved and consolidated before
  exiting the application or moving on to the next step in the workflow.
  """
  def join() do
    UI.debug("[notes-server]", "waiting for operations to complete")
    GenServer.call(__MODULE__, :join, :infinity)
  end

  @doc """
  Saves the new notes that have been collected over the course of the current
  session to persistent storage. This saves any newly extracted facts and user
  insights that have not yet been consolidated into the main research notes.

  Returns immediately, but the actual saving process may take some time. Use
  `join/0` to wait for the server to complete all operations if needed.

  The new notes are added to a special section at the end of the existing
  research notes, labeled `# NEW NOTES (unconsolidated)`. This section is meant
  to be consolidated later by the `consolidate/0` function.
  """
  def save() do
    UI.debug("[notes-server]", "saving new research")
    GenServer.cast(__MODULE__, :save)
  end

  # -----------------------------------------------------------------------------
  # Server API
  # -----------------------------------------------------------------------------
  def init(_opts) do
    {:ok, AI.Notes.new()}
  end

  def handle_cast(:load_notes, state) do
    {:noreply, AI.Notes.init(state)}
  end

  def handle_cast({:ingest_user_msg, msg_text}, state) do
    {:noreply, AI.Notes.ingest_user_msg(state, msg_text)}
  end

  def handle_cast({:ingest_research, func, args_json, result}, state) do
    {:noreply, AI.Notes.ingest_research(state, func, args_json, result)}
  end

  def handle_cast(:consolidate, state) do
    if AI.Notes.has_new_facts?(state) do
      state
      |> AI.Notes.consolidate()
      |> case do
        {:ok, result} ->
          UI.info("[notes-server]", "consolidated existing research notes")
          {:noreply, result}

        {:error, reason} ->
          UI.error("[notes-server]", "failed to consolidate notes: #{reason}")
          {:noreply, state}
      end
    else
      UI.debug("[notes-server]", "no new notes; skipping consolidation")
      {:noreply, state}
    end
  end

  def handle_cast(:save, state) do
    AI.Notes.commit(state)
    {:noreply, state}
  end

  def handle_call({:ask, question}, _from, state) do
    {:reply, AI.Notes.ask(state, question), state}
  end

  # Just a placeholder for a no-op `call` to allow the client to know that the
  # server has completed all operations prior to the call to `join/0`.
  def handle_call(:join, _from, state) do
    {:reply, :ok, state}
  end
end
