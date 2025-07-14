defmodule AI.Notes do
  @moduledoc """
  Coordinates the mini-agents that manage project research notes. The workflow for this is:
  1. Initialize the notes with `init/1`, which loads existing notes from disk.
  2. Consolidate new notes from the prior research session.
     This incorporates the new facts in the `NEW NOTES` section into the main body of the notes file.
  3. As user prompts arrive, ingest user messages with `ingest_user_msg/2`, which updates the user traits based on the user's messages.
  4. As tool calls are made, ingest research results with `ingest_research/4`, which extracts facts from the tool call results.
  5. Commit the newly gathered facts to disk with `commit/1`, which appends the new facts to the existing notes.
     The new facts are stored in a special `NEW NOTES` section that is recognized by the consolidation agent.
     These will be incorporated into the main notes body at the beginning of the next session.

  The reason for this inverted workflow is because the consolidation process takes much longer than any of the other steps.
  By performing it at the outset of a session, we reduce the impact of that unfortunate, abeit necessary, time delay on the user experience.
  """

  defstruct [
    :notes,
    :user,
    :new_facts
  ]

  @type t :: %__MODULE__{
          notes: binary,
          user: binary,
          new_facts: list(binary)
        }

  @typep mini_agent :: %{
           model: AI.Model.t(),
           prompt: binary
         }

  # ----------------------------------------------------------------------------
  # Mini Agent defs
  # ----------------------------------------------------------------------------
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

  @research %{
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

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------
  @spec new() :: t
  def new() do
    %__MODULE__{
      notes: "",
      user: "",
      new_facts: []
    }
  end

  @spec init(t) :: t
  def init(state) do
    notes = load_notes()
    user = extract_user_section(notes)
    %{state | notes: notes, user: user, new_facts: []}
  end

  @spec commit(t) :: {:ok, t} | {:error, any}
  def commit(state) do
    # Get the most recent copy of the notes, just in case another session was
    # running in parallel and modified them on disk.
    notes = load_notes()
    facts = format_new_notes(state)

    notes = """
    #{notes}

    # NEW NOTES (unconsolidated)
    #{facts}
    """

    Store.Project.Notes.write(notes)
    |> case do
      :ok ->
        UI.info("New notes saved in project data")
        {:ok, %{state | new_facts: [], notes: notes}}

      {:error, reason} ->
        UI.error("Error saving new notes", reason)
        {:error, reason}
    end
  end

  @spec ingest_user_msg(t, binary) :: t
  def ingest_user_msg(state, msg_text) do
    """
    Background on the user (from your previous notes):
    #{state.user}

    The user said:
    > #{msg_text}
    """
    |> completion(@user)
    |> case do
      {:ok, response} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "n/a" -> state
          facts -> %{state | new_facts: [facts | state.new_facts]}
        end

      {:error, reason} ->
        UI.warn("Failed to ingest user message: #{inspect(reason)}")
        state
    end
  end

  @spec ingest_research(t, binary, binary, any) :: t
  def ingest_research(state, func, args_json, result) do
    """
    The following tool call was made:

    **Function:** #{func}
    **Arguments:**
    ```json
    #{args_json}
    ```

    The result of the tool call was:
    #{inspect(result, pretty: true)}
    """
    |> completion(@research)
    |> case do
      {:ok, response} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "n/a" -> state
          facts -> %{state | new_facts: [facts | state.new_facts]}
        end

      {:error, reason} ->
        UI.error("Failed to ingest research: #{inspect(reason)}")
        state
    end
  end

  @spec consolidate(t) :: t
  def consolidate(state) do
    """
    Please reorganize and consolidate the following project notes according to the specified guidelines.
    -----
    #{state.notes}
    """
    |> completion(@consolidate)
    |> case do
      {:ok, response} ->
        response
        |> clean_notes_string()
        |> case do
          {:error, :empty_string} ->
            UI.debug("Notes Consolidation Agent returned an empty string")
            state

          {:ok, notes} ->
            notes
            |> Store.Project.Notes.write()
            |> case do
              :ok ->
                UI.info("Consolidated notes saved")
                %{state | notes: notes, new_facts: []}

              {:error, reason} ->
                UI.error("Failed to save consolidated notes: #{inspect(reason)}")
                state
            end
        end

      {:error, reason} ->
        UI.error("Failed to consolidate notes: #{inspect(reason)}")
        state
    end
  end

  @spec ask(t, binary) :: binary
  def ask(state, question) do
    """
    The following are the existing research notes about the project.
    #{state.notes}

    # New facts:
    The following are the new facts that have been collected during the current session.
    #{format_new_notes(state)}

    # Question
    Please answer the following question based on the existing notes and new facts:
    #{question}
    """
    |> completion(@ask)
    |> case do
      {:ok, response} ->
        response
        |> String.trim()
        |> case do
          "" -> "No relevant information found."
          answer -> answer
        end

      {:error, reason} ->
        UI.error("[notes-server] failed to answer question", reason)
        "Error processing request."
    end
  end

  # ----------------------------------------------------------------------------
  # Utility Functions
  # ----------------------------------------------------------------------------
  @spec load_notes() :: binary
  defp load_notes() do
    with {:ok, notes} <- Store.Project.Notes.read() do
      notes
    else
      {:error, :enoent} ->
        UI.warn("No existing notes found, starting fresh")
        ""

      {:error, reason} ->
        UI.error("Failed to load notes: #{inspect(reason)}")
        ""
    end
  end

  @spec clean_notes_string(binary) :: {:ok, binary} | {:error, :empty_string}
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

  @spec extract_user_section(binary) :: binary
  defp extract_user_section(""), do: ""

  defp extract_user_section(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.drop_while(&(!String.starts_with?(&1, "# USER")))
    |> case do
      [section | _] -> section
      [] -> ""
    end
  end

  @spec format_new_notes(t) :: binary
  defp format_new_notes(state) do
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

  @spec completion(binary, mini_agent) :: {:ok, binary} | {:error, any}
  defp completion(input, agent) do
    AI.Completion.get(
      log_messages: false,
      log_tool_calls: false,
      model: agent.model,
      messages: [
        AI.Util.system_msg(agent.prompt),
        AI.Util.user_msg(input)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
