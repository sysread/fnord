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
    :user,
    :new_facts
  ]

  @type t :: %__MODULE__{
          user: binary,
          new_facts: list(binary)
        }

  @typep mini_agent :: %{
           model: AI.Model.t(),
           prompt: binary
         }

  @attempts 2

  # ----------------------------------------------------------------------------
  # Mini Agent defs
  # ----------------------------------------------------------------------------
  @user %{
    model: AI.Model.turbo(),
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
    model: AI.Model.turbo(),
    prompt: """
    You are a research assistant that extracts facts about the project from tool call results.
    Extract **non-transient** facts about the project from the tool call result.
    If the tool call is a notification (notify_tool) and its message includes explicit memory memos (e.g., lines starting with "note to self:" or "remember:"), extract those memos verbatim as new facts. Treat them as high-priority, non-transient notes unless they clearly refer to ephemeral states (e.g., temporary delays, transient errors).
    Normalize prefixes to a single dash list item.
    Transient facts are those that are not persistently relevant, such as current repo state, individual tickets or projects, PRs, or changes.
    You are concerned with the overall project architecture, design, and implementation details that are relevant to understanding the project as a whole.
    Focus on the most important details that would help someone understand the project quickly and effectively.
    Topics of interest include (but are not limited to):
    - Project purpose and goals
    - Languages, frameworks, and technologies used
    - Coding, style, and testing conventions
    - Repo/app layout and organization
    - Applications and components, their locations, and dependencies
    - Any other notes about how the code behaves, integrates, etc.
    - Details about individual features, components, modules, tests, etc.
    - Gotchas and pitfalls to avoid
    - "Always check X before doing Y" type of advice
    Respond with a formatted markdown list of facts without any additional text.
    If nothing was identified, respond with "N/A" on a single line.
    Just the facts, ma'am!
    """
  }

  @ask %{
    model: AI.Model.turbo(),
    prompt: """
    You are a research assistant that answers questions about past research done on the project.
    Your role is to provide concise, accurate answers based on the existing project notes.
    When asked a question, extract all relevant information from the existing notes and organize it effectively based on your understanding of the requestor's needs.
    """
  }

  @consolidate %{
    model: AI.Model.large_context(:smart),
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
      user: "",
      new_facts: []
    }
  end

  @spec init(t) :: t
  def init(state) do
    notes = load_notes()
    user = extract_user_section(notes)
    %{state | user: user, new_facts: []}
  end

  @spec commit(t) :: {:ok, t} | {:error, any}
  def commit(state) do
    # Get the most recent copy of the notes, just in case another session was
    # running in parallel and modified them on disk.
    notes = load_notes()

    # Format the new facts into a markdown list
    facts = format_new_notes(state)

    # If there is already a `# NEW NOTES (unconsolidated)` section, append to it.
    notes =
      if Regex.match?(~r/(?mi)^# NEW NOTES \(unconsolidated\)$/, notes) do
        """
        #{notes}
        #{facts}
        """
      else
        """
        #{notes}

        # NEW NOTES (unconsolidated)
        #{facts}
        """
      end

    Store.Project.Notes.write(notes)
    |> case do
      :ok ->
        {:ok, %{state | new_facts: []}}

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
    |> complete(@user)
    |> case do
      {:ok, response} ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "n/a" -> state
          facts -> %{state | new_facts: [facts | state.new_facts]}
        end

      otherwise ->
        log_failure(otherwise, "Failed to ingest user message")
        state
    end
  end

  @spec ingest_memo(t, binary) :: t
  def ingest_memo(state, memo) do
    memo = "Important note to self: #{memo}"
    %{state | new_facts: [memo | state.new_facts]}
  end

  @spec ingest_research(t, binary, binary, any) :: t
  def ingest_research(state, func, args_json, result) do
    # Prepare input for AI and detect any memos from notify_tool
    input = """
    The following tool call was made:

    **Function:** #{func}
    **Arguments:**
    ```json
    #{args_json}
    ```

    The result of the tool call was:
    #{inspect(result, pretty: true)}
    """

    extra_facts =
      case func do
        "notify_tool" ->
          with {:ok, decoded} <- Jason.decode(args_json),
               %{"message" => msg} <- decoded do
            msg
            |> String.split(["\n", "\r\n"], trim: true)
            |> Enum.filter(fn line ->
              l = String.downcase(String.trim_leading(line))
              String.starts_with?(l, "note to self:") or String.starts_with?(l, "remember:")
            end)
            |> Enum.map(fn line ->
              line
              |> String.replace(~r/^\s*[-*]\s*/, "")
              |> String.trim()
            end)
            |> Enum.map(&("- " <> &1))
            |> Enum.join("\n")
          else
            _ -> nil
          end

        _ ->
          nil
      end

    complete(input, @research)
    |> case do
      {:ok, response} ->
        # Merge AI facts and any extra_facts
        new_state =
          case String.downcase(String.trim(response)) do
            "n/a" -> state
            facts -> %{state | new_facts: [facts | state.new_facts]}
          end

        new_state =
          case extra_facts do
            nil -> new_state
            "" -> new_state
            ef -> %{new_state | new_facts: [ef | new_state.new_facts]}
          end

        new_state

      otherwise ->
        log_failure(otherwise, "Failed to ingest research")
        state
    end
  end

  @spec consolidate(t, non_neg_integer) :: {:ok, t} | {:error, binary}
  def consolidate(state, attempt \\ 1) do
    with_lock(fn ->
      fresh = load_notes() |> collapse_unconsolidated_sections()

      """
      Please reorganize and consolidate the following project notes according to the specified guidelines.
      -----
      #{fresh}
      """
      |> accumulate(@consolidate)
      |> case do
        {:ok, response} ->
          response
          |> clean_notes_string()
          |> case do
            {:error, :empty_string} ->
              {:error, "Notes Consolidation Agent returned an empty string"}

            {:ok, notes} ->
              notes
              |> Store.Project.Notes.write()
              |> case do
                :ok -> {:ok, %{state | new_facts: []}}
                otherwise -> otherwise
              end
          end

        otherwise ->
          if attempt < @attempts do
            consolidate(state, attempt + 1)
          else
            log_failure(otherwise, "Failed to consolidate notes after #{@attempts} attempts")
            otherwise
          end
      end
    end)
  end

  @spec ask(t, binary, non_neg_integer) :: binary
  def ask(state, question, attempt \\ 1) do
    with_lock(fn ->
      fresh = load_notes() |> collapse_unconsolidated_sections()

      """
      The following are the existing research notes about the project.
      #{fresh}

      # New facts:
      The following are the new facts that have been collected during the current session.
      #{format_new_notes(state)}

      # Question
      Please answer the following question based on the existing notes and new facts:
      #{question}
      """
      |> complete(@ask)
      |> case do
        {:ok, response} ->
          response
          |> String.trim()
          |> case do
            "" -> "No relevant information found."
            answer -> answer
          end

        otherwise ->
          if attempt < @attempts do
            ask(state, question, attempt + 1)
          else
            log_failure(otherwise, "Failed to answer question after #{@attempts} attempts")
            "Error processing request."
          end
      end
    end)
  end

  @doc """
  Returns `true` if the given notes struct's text contains the section header
  "# new notes (unconsolidated)" (case-insensitive), indicating uncategorized
  notes pending consolidation.
  """
  @spec has_new_facts?() :: boolean
  def has_new_facts?() do
    case Store.Project.Notes.read() do
      {:ok, notes} ->
        notes
        |> String.downcase()
        |> String.contains?("# new notes (unconsolidated)")

      {:error, :no_notes} ->
        false

      _ ->
        false
    end
  end

  @deprecated "use has_new_facts?/0"
  @spec has_new_facts?(t) :: boolean
  def has_new_facts?(_state), do: has_new_facts?()

  # ----------------------------------------------------------------------------
  # Utility Functions
  # ----------------------------------------------------------------------------
  @spec with_lock((-> any)) :: any
  defp with_lock(func) do
    with {:ok, path} <- Store.Project.Notes.file_path(),
         {:ok, result} <- FileLock.with_lock(path, func) do
      result
    end
  end

  @spec load_notes() :: binary
  defp load_notes() do
    with {:ok, notes} <- Store.Project.Notes.read() do
      notes
    else
      {:error, :no_notes} ->
        ""

      otherwise ->
        log_failure(otherwise, "Failed to load notes")
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

  @spec complete(binary, mini_agent) :: {:ok, binary} | {:error, any}
  defp complete(input, agent) do
    AI.Completion.get(
      log_messages: false,
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

  @spec accumulate(binary, mini_agent) :: {:ok, binary} | {:error, any}
  defp accumulate(input, agent) do
    AI.Accumulator.get_response(
      model: agent.model,
      prompt: agent.prompt,
      input: input,
      question: "Please consolidate the following notes according to the specified guidelines."
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_failure({:error, %{response: reason}}, of_what) do
    UI.warn("#{of_what}: #{inspect(reason, pretty: true)}")
  end

  defp log_failure({:error, reason}, of_what) do
    UI.warn("#{of_what}: #{inspect(reason, pretty: true)}")
  end

  def collapse_unconsolidated_sections(text) do
    pattern = ~r/^# NEW NOTES \(unconsolidated\)\r?\n([\s\S]*?)(?=^# |\z)/mi

    blocks =
      Regex.scan(pattern, text)
      |> Enum.map(fn [_full, content] -> content end)

    items =
      blocks
      |> Enum.flat_map(fn block ->
        block
        |> String.split("\n", trim: false)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(fn line ->
          line
          |> String.replace(~r/^\s*[-*]\s*/, "")
          |> (&("- " <> &1)).()
        end)
      end)
      |> Enum.reduce({[], MapSet.new()}, fn item, {acc, seen} ->
        key = String.downcase(item)

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[item | acc], MapSet.put(seen, key)}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    doc = Regex.replace(pattern, text, "")

    if items == [] do
      doc
    else
      # ensure exactly one blank line before the canonical block
      doc_trim = Regex.replace(~r/\n+\z/, doc, "")
      doc_trim <> "\n\n# NEW NOTES (unconsolidated)\n" <> Enum.join(items, "\n") <> "\n"
    end
  end
end
