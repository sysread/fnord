defmodule NotesServer do
  use GenServer

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    UI.debug("[notes-server] starting")
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
    UI.debug("[notes-server] consolidating existing research")
    GenServer.cast(__MODULE__, :consolidate)
  end

  @doc """
  Commits the new notes that have been collected over the course of the current
  session to persistent storage. This saves any newly extracted facts and user
  insights that have not yet been consolidated into the main research notes.

  The new notes are added to a special section at the end of the existing
  research notes, labeled `# NEW NOTES (unconsolidated)`. This section is meant
  to be consolidated later by the `consolidate/0` function.
  """
  @spec commit() :: :ok | {:error, any}
  def commit() do
    UI.debug("[notes-server] committing new notes to persistent storage")
    GenServer.call(__MODULE__, :commit, :infinity)
  end

  # -----------------------------------------------------------------------------
  # Server API
  # -----------------------------------------------------------------------------
  @user %{
    model: AI.Model.fast(),
    prompt: """
    You are a highly empathetic AI assistant that gleans knowledge about the user from the tone and content of their messages.
    Your role is to attempt to deduce the user's coding preferences, learning style, personality, and other relevant traits based on their interactions.
    Respond with a formatted markdown list of user traits without any additional text.
    Additionally, note if you identify that a prior learning about the user was incorrect or is no longer valid.
    Each item should mention that is is a trait of the user, e.g.: "User is experienced with Elixir"
    If nothing was identified, respond with "N/A" on a single line.
    """
  }

  @facts %{
    model: AI.Model.fast(),
    prompt: """
    You are a research assistant that extracts facts about the project from tool call results.
    Extract every non-transient fact about the project from the tool call result.
    Topics of interest include (but are not limited to):
    - Project purpose and goals
    - Languages, frameworks, and technologies used
    - Coding, style, and testing conventions
    - Repo/app layout and organization
    - Applications and components, their locations, and dependencies
    - Any other notes about how the code behaves, integrates, etc.
    - Details about individual features, components, modules, tests, etc.
    Respond with a formatted markdown list of facts without any additional text.
    If nothing was identified, respond with "N/A" on a single line.
    Just the facts, ma'am!
    """
  }

  @ask %{
    model: AI.Model.fast(),
    prompt: """
    You are a research assistant that answers questions about past research done on the project.
    Your role is to provide concise, accurate answers based on the existing project notes.
    When asked a question, extract all relevant information from the existing notes and organize it effectively based on your understanding of the requestor's needs.
    """
  }

  @consolidate %{
    model: AI.Model.smart(),
    prompt: """
    You are a research assistant that consolidates and organizes project notes.
    Your role is to incorporate newly extracted facts into existing project notes, ensuring that all information is accurate, up-to-date, and well-organized.
    DO NOT lose ANY prior facts that were not disproven by the new notes.
    Respond with the updated notes in markdown format, without any additional text, wrapping code fences, or explanations.

    Newly organized facts will appear at the end of the existing notes in the document you are provided.
    There may be multiple `# NEW NOTES (unconsolidated)` sections, each containing a list of new facts.
    These should be consolidated into the existing notes.
    The `# NEW NOTES (unconsolidated)` section(s) are removed after being incorporated into the document proper.

    Goals:
    - **Overall Goal:** Manage a well-organized, comprehensive, archive of research notes about the project.
    - Dismiss ephemeral facts that (e.g. about individual tickets, PRs, or changes) that are not persistently relevant.
    - Conflicting facts should be resolved by keeping the most recent information.
    - Ensure the notes are organized by topic and concise.
    - Combine nearly identical facts into a single entry.
    - Reorganize as needed to improve clarity and flow.

    Response Template:
    # SYNOPSIS
    [Summary of project purpose]

    # USER
    [Bullet list of knowledge about the user, preferences, and relevant traits]

    # LANGUAGES AND TECHNOLOGIES
    [Bullet list of languages, frameworks, and technologies used in the project]

    # CONVENTIONS
    [Bullet list of coding conventions, style pointers, test conventions followed in the project]

    # LAYOUT
    [Repo/app layout, interaction, organization]

    # APPLICATIONS & COMPONENTS
    [For each app/component: brief description, location, dependencies]

    # NOTES
    [Organized by topic: subheading per topic, then a list of facts]
    """
  }

  def init(_opts) do
    {:ok, %{notes: "", user: "", new_facts: []}}
  end

  def handle_cast(:load_notes, state) do
    with {:ok, notes} <- Store.Project.Notes.read() do
      # Parse out USER section
      user_section = extract_user_section(notes)
      {:noreply, %{state | notes: notes, user: user_section}}
    else
      # No notes yet
      {:error, :enoent} ->
        {:noreply, %{state | notes: "", new_facts: []}}

      {:error, reason} ->
        UI.error("[notes-server] failed to load notes", inspect(reason))
        {:noreply, state}
    end
  end

  def handle_cast({:ingest_user_msg, msg_text}, state) do
    AI.Completion.get(
      log_messages: false,
      log_tool_calls: false,
      model: @user.model,
      messages: [
        AI.Util.system_msg(@user.prompt),
        AI.Util.user_msg("""
        Background on the user (from your previous notes):
        #{state.user}

        The user said:
        > #{msg_text}
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "n/a" -> {:noreply, state}
          facts -> {:noreply, %{state | new_facts: [facts | state.new_facts]}}
        end

      {:error, reason} ->
        UI.error("[notes-server] failed to ingest research", reason)
        {:noreply, state}
    end
  end

  def handle_cast({:ingest_research, func, args_json, result}, state) do
    AI.Completion.get(
      log_messages: false,
      log_tool_calls: false,
      model: @facts.model,
      messages: [
        AI.Util.system_msg(@facts.prompt),
        AI.Util.user_msg("""
        The following tool call was made:

        **Function:** #{func}
        **Arguments:**
        ```json
        #{args_json}
        ```

        The result of the tool call was:
        #{inspect(result, pretty: true)}
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "n/a" -> {:noreply, state}
          facts -> {:noreply, %{state | new_facts: [facts | state.new_facts]}}
        end

      {:error, reason} ->
        UI.error("[notes-server] failed to ingest research", reason)
        {:noreply, state}
    end
  end

  def handle_cast(:consolidate, state) do
    input = """
    Please reorganize and consolidate the following project notes according to the specified guidelines.
    -----
    #{state.notes}
    """

    AI.Completion.get(
      log_messages: false,
      log_tool_calls: false,
      model: @consolidate.model,
      messages: [
        AI.Util.system_msg(@consolidate.prompt),
        AI.Util.user_msg(input)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> clean_notes_string()
        |> case do
          {:error, :empty_string} ->
            UI.warn("[notes-server] consolidation agent responded with an empty string :/")
            {:noreply, state}

          {:ok, notes} ->
            notes
            |> Store.Project.Notes.write()
            |> case do
              :ok ->
                UI.info("[notes-server] notes consolidated and saved")
                {:noreply, %{state | notes: notes, new_facts: []}}

              {:error, reason} ->
                UI.error("[notes-server] failed to save consolidated notes", reason)
                {:noreply, state}
            end

            {:noreply, %{state | notes: notes}}
        end

      {:error, reason} ->
        UI.error("[notes-server] failed to consolidate notes", reason)
        {:noreply, state}
    end
  end

  def handle_call(:commit, _from, state) do
    # Get the most recent copy of the notes, just in case another session was
    # running in parallel.
    with {:ok, notes} <- Store.Project.Notes.read() do
      facts = format_notes(state)

      notes = """
      #{notes}

      # NEW NOTES (unconsolidated)
      #{facts}
      """

      Store.Project.Notes.write(notes)
      |> case do
        :ok ->
          UI.info("[notes-server] new notes saved")
          {:reply, :ok, %{state | new_facts: [], notes: notes}}

        {:error, reason} ->
          UI.error("[notes-server] error saving new notes", reason)
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:ask, question}, _from, state) do
    AI.Completion.get(
      log_messages: false,
      log_tool_calls: false,
      model: @ask.model,
      messages: [
        AI.Util.system_msg(@ask.prompt),
        AI.Util.user_msg("""
        The following are the existing research notes about the project.
        #{state.notes}
        """),
        AI.Util.user_msg("""
        # New facts:
        The following are the new facts that have been collected during the current session.
        #{format_notes(state)}
        """),
        AI.Util.user_msg("""
        #{question}
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> String.trim()
        |> case do
          "" -> {:reply, "No relevant information found.", state}
          answer -> {:reply, answer, state}
        end

      {:error, reason} ->
        UI.error("[notes-server] failed to answer question", reason)
        {:reply, "Error processing request.", state}
    end
  end

  # -----------------------------------------------------------------------------
  # Utility Functions
  # -----------------------------------------------------------------------------
  defp clean_notes_string(input) do
    trimmed =
      input
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.join("\n")

    if Regex.match?(~r/[[:graph:]]/, trimmed) do
      {:ok, trimmed}
    else
      {:error, :empty_string}
    end
  end

  defp extract_user_section(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.drop_while(&(!String.starts_with?(&1, "# USER")))
    |> case do
      [section | _] -> section
      [] -> ""
    end
  end

  defp format_notes(state) do
    state.new_facts
    |> Enum.reverse()
    |> Enum.flat_map(&String.split(&1, "\n", trim: true))
    |> Enum.map(fn fact ->
      cond do
        # list item w/o indentation
        String.starts_with?(fact, "- ") -> fact
        # list item with indentation
        fact |> String.trim() |> String.starts_with?("- ") -> fact
        # not a list item, so make it one
        true -> "- #{fact}"
      end
    end)
    |> Enum.join("\n")
  end
end
