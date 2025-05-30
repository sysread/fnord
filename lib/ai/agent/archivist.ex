defmodule AI.Agent.Archivist do
  # This is important, because balanced() has a 1m token context window, and we
  # are stuffing a LOT of content into it: both the conversation transcript as
  # well as ALL prior research notes.
  @model AI.Model.balanced()

  @prompt """
  # Your Role
  You are the Archivist AI Agent.
  You are in charge of maintaining and organizing research about this project.
  You have previously stored notes from earlier research sessions.
  You will be provided a transcript of new research performed by the Orchestrating Agent on behalf of the user.
  Organize and file the facts discovered during the research for future reference, incorporating them into your notes from prior research.
  Your saved notes will be used in future responses to more accurately answer the user's question.

  # Research Notes
  Many code bases are long-lived, with multiple languages, changes to terminology that are inconsistently applied, and ambiguous or stale documentation.
  Your saved research notes will guide future research to avoid these pitfalls.

  Examples of useful information to save:
  - Ambiguities in phrasing:
    - Inconsistent phrasing
    - Components or concepts with names that are similar to other components
    - Components or concepts that are referenced by multiple names
    - Components or concepts that have unexpected names that do not match their behavior
    - Changes in terminology or naming conventions over time
  - Rabbit holes
    - eg "Component X looks like it is related to Feature Y, but is is instead part of Feature Z"
    - eg "The README claims ..., but in fact ..."
  - Identifying inaccurate documentation or comments in the code base so we aren't fooled by them twice
  - The purpose of a file, component, or concept
  - Relationships between files, components, and/or concepts
  - The location or single source of truth for a concept
  - Data flow between components and application boundaries
  - Organization of apps within the code base; in particular, each apps':
    - Purpose
    - Role
    - Dependencies
    - Relationships to other apps
    - Data flow between apps
    - Shared components and where they are located
    - Sharing mechanisms between apps
    - CI/CD and build workflows
  - Organization of components, ESPECIALLY if its confusing
  - Research strategies that worked well or poorly
  - Anything else that you think might might be useful or prevent us from getting tripped up in the future

  # Directions
  Read the transcript and identify ALL facts that were discovered about the code base.
  Include facts even if (ESPECIALLY if) unrelated to the user's prompt.

  Read the existing research notes and incorporate the new research into them:
  - Remove any facts that were disproven
  - Update any facts that were changed or clarified
  - Update any stale information that was corrected
  - Add all new facts that were discovered
  - Consolidate and reorganize as appropriate to reduce duplication and token usage
  - Organize the facts by topic
  - Use markdown headers for each topic, followed by a list of facts

  # Structure
  Use the following template (between the dashed lines, but not including them):
  -----
  # SYNOPSIS
  [summary of the purpose of the project]

  # LAYOUT
  [explain the layout of the repo; is it a monorepo? how do the apps interact? how are they organized?]

  # APPLICATIONS & COMPONENTS
  [for each app or primary/top-level component, provide a brief description, location, and dependencies]

  # NOTES
  [organize notes by topic, with a subheading for each topic, and a list of facts]
  -----

  # IMPORTANT:
  - **Do not lose existing facts that were NOT disproven by the new research transcript**
  - **If you do not include all of the prior research notes, they will be gone forever, until the next time we re-disover them.**
  - **SERIOUSLY, ++PLEASE++ DO NOT LOSE ANY FACTS THAT WERE NOT DISPROVEN**

  Respond ONLY with the updated research notes, organized as a markdown file, without preamble or explanation, in markdown format, WITHOUT fences.
  Just the notes text, my dude.
  """

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, transcript} <- Map.fetch(opts, :transcript),
         {:ok, max_tokens} <- Map.fetch(opts, :max_tokens),
         {:ok, old_notes} <- fetch_notes(),
         {:ok, compressed} <- compress_notes(old_notes, max_tokens),
         {:ok, organized} <- organize_notes(transcript, compressed),
         :ok = Store.Project.Notes.write(organized) do
      {:ok, organized}
    else
      {:compress_error, reason} -> {:error, "failed to compress notes: #{reason}"}
      {:organize_error, reason} -> {:error, "failed to organize notes: #{reason}"}
    end
  end

  # Recursively compress notes until under max_tokens
  defp compress_notes(notes, max_tokens) do
    count = AI.PretendTokenizer.guesstimate_tokens(notes)
    count_str = Util.format_number(count)
    max_tokens_str = Util.format_number(max_tokens)

    if count <= max_tokens do
      UI.report_step("Compressing prior research", "Nothing to do")
      {:ok, notes}
    else
      UI.report_step(
        "Compressing prior research",
        "Attempting to compress to within #{max_tokens_str} tokens (currently at #{count_str})"
      )

      prompt = """
      # Your Role
      You are the Archivist AI Agent.
      The existing research notes exceed the allowed token limit.
      Compress and reorganize to retain all facts and remove redundancies.
      DO NOT LOSE ANY FACTS.

      # Notes
      #{notes}
      """

      AI.Accumulator.get_response(
        model: @model,
        prompt: prompt,
        input: notes,
        question: "Compress research notes to ≤ #{max_tokens_str} tokens."
      )
      |> case do
        {:ok, %{response: compressed}} -> compress_notes(compressed, max_tokens)
        {:error, reason} -> {:compress_error, reason}
      end
    end
  end

  defp organize_notes(transcript, old_notes) do
    UI.report_step("Updating prior research", "Assimilating new research into existing notes")

    input = """
    # NEW RESEARCH TRANSCRIPT
    #{transcript}

    # EXISTING RESEARCH NOTES
    #{old_notes}
    """

    AI.Accumulator.get_response(
      model: @model,
      prompt: @prompt,
      input: input,
      question: "Organize, integrate, and file new facts into your existing research notes."
    )
    |> case do
      {:ok, %{response: organized}} -> {:ok, organized}
      {:error, reason} -> {:organize_error, reason}
    end
  end

  defp fetch_notes() do
    case Store.Project.Notes.read() do
      {:ok, notes} -> {:ok, notes}
      {:error, :no_notes} -> {:ok, "No research has been conducted yet"}
    end
  end
end
