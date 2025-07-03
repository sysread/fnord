defmodule AI.Agent.Archivist do
  @model AI.Model.fast()

  @base_prompt """
  # Synopsis
  You are the Archivist AI Agent.
  You are in charge of maintaining and organizing research about this project.
  You have previously stored notes from earlier research sessions.
  You are responsible for managing one section of those notes.
  Your role is to analyze a transcript of new research performed by the Orchestrating Agent on behalf of the user.
  Your saved notes will be used in future responses to more accurately answer the user's question.

  # Directions
  Read the transcript and identify ALL facts that were discovered about the code base.
  Include facts even if (ESPECIALLY if) unrelated to the user's prompt.

  Read the existing research notes and incorporate the new research into them:
  - Remove any facts that were directly disproven
  - Update any facts that were changed or clarified
  - Update any stale information that was corrected
  - Add all new facts that were discovered
  - Consolidate and reorganize as appropriate to reduce duplication and token usage
  - Organize the facts by topic
  - Use markdown headers (h2+) for each topic, followed by a list of facts

  IMPORTANT:
  - **Do not lose existing facts that were NOT disproven by the new research transcript**
  - **If you do not include all of the prior research notes, they will be gone forever, until the next time we re-disover them.**
  - **SERIOUSLY, ++PLEASE++ DO NOT LOSE ANY FACTS THAT WERE NOT DISPROVEN**

  Respond ONLY with YOUR updated section of the research notes, organized as a markdown file, without preamble or explanation, in markdown format, WITHOUT fences.
  Just the notes text, my dude.
  """

  @analyzers %{
    "User" => """
    # Your Role
    You are responsible for the `USER` section of the notes.
    Analyze the transcript, focusing on the user's messages.
    Observe their phrasing, tone, concerns, and reactions to the Orchestrating Agent's responses, if present.
    Theorize what the user might prefer in terms of coding style, commenting style, and personality traits.
    Try to intuit how the user processes information and what they might find helpful or unhelpful in future interactions.

    In particular, look for:
    - Coding styles
    - Coding conventions
    - Commenting style
    - Personality traits and quirks
    - Preferences for how information is presented

    Incorporate your findings into the text of the `USER` section of the notes.
    Respond with the complete, updated text.
    """,
    "Synopsis" => """
    # Your Role
    You are responsible for the `SYNOPSIS` section of the notes.
    Analyze the transcript and prior notes to maintain an up-to-date, concise summary of the purpose and scope of the project.
    Focus on the high-level goal, target audience, and core functionality as described in new research.
    Update this section to reflect any major shifts or clarified understanding.

    In particular, look for:
    - High-level purpose of the codebase or project
    - Key objectives, capabilities, and boundaries
    - Any clarified or corrected misconceptions about what the project is or does

    Incorporate your findings into the text of the `SYNOPSIS` section of the notes.
    Respond with the complete, updated text.
    """,
    "Layout" => """
    # Your Role
    You are responsible for the `LAYOUT` section of the notes.
    Analyze the transcript and prior notes to update and clarify the structure of the codebase.
    Note the organization of applications, components, and modules, and how they interact.
    Focus on the overall directory structure, major subfolders, and how different parts of the repo relate or communicate.

    In particular, look for:
    - Whether the repo is a monorepo or multi-repo
    - Top-level organization and naming of directories or apps
    - Relationships and interactions between major parts of the codebase
    - Any architectural boundaries or points of integration

    Incorporate your findings into the text of the `LAYOUT` section of the notes.
    Respond with the complete, updated text.
    """,
    "Applications & Components" => """
    # Your Role
    You are responsible for the `APPLICATIONS & COMPONENTS` section of the notes.
    For each application or major top-level component in the codebase, provide a brief description, location (path), and dependencies.
    Analyze the transcript and prior notes for new facts about each app/component, its purpose, its relationships, and any changes in dependencies or roles.

    In particular, look for:
    - New applications or components introduced/discovered
    - Changes to the purpose or role of any app/component
    - Updates to locations or dependencies
    - New relationships or clarified connections between apps/components

    Incorporate your findings into the text of the `APPLICATIONS & COMPONENTS` section of the notes.
    Respond with the complete, updated text.
    """,
    "Notes" => """
    # Your Role
    You are responsible for the `NOTES` section of the research notes.
    Organize notes by topic, using subheadings for each topic and a list of facts under each.
    Focus on capturing insights, gotchas, known ambiguities, research strategies, pitfalls, changes in terminology, and anything that may be useful in future research.

    In particular, look for:
    - Ambiguities, rabbit holes, and misleading documentation or comments
    - Clarifications or corrections to prior misunderstandings
    - Terminology drift (components referenced by multiple names, etc)
    - Purpose and relationships of files/components/concepts
    - Data flow, application boundaries, shared components, and workflows
    - CI/CD, build systems, and organization of components
    - Research strategies that worked well or poorly
    - Any additional facts that might prevent confusion in the future

    Structure the section using markdown headers (h2+ - NEVER h1) for each topic and bullet lists for facts under each.
    Incorporate your findings into the text of the `NOTES` section of the notes.
    Respond with the complete, updated text.
    """
  }

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, transcript} <- Map.fetch(opts, :transcript),
         {:ok, old_notes} <- fetch_notes(),
         {:ok, notes} <- organize_notes(old_notes, transcript),
         :ok <- Store.Project.Notes.write(notes) do
      {:ok, notes}
    end
  end

  defp fetch_notes() do
    case Store.Project.Notes.read() do
      {:ok, notes} -> {:ok, notes}
      {:error, :no_notes} -> {:ok, "No research has been conducted yet"}
    end
  end

  defp organize_notes(notes, transcript) do
    @analyzers
    |> Map.keys()
    |> Util.async_stream(fn section ->
      existing_notes = Map.get(notes, section, "(no notes have been saved for this section yet)")
      analyze_section(section, existing_notes, transcript)
    end)
    |> Enum.flat_map(fn
      {:ok, {:ok, section, response}} -> {section, response}
      _ -> []
    end)
    |> Map.new()
    |> then(&{:ok, &1})
  end

  defp analyze_section(section, notes, transcript) do
    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@base_prompt <> "\n\n" <> @analyzers[section]),
        AI.Util.user_msg("""
        # Existing notes for "#{section}"
        #{notes}

        # Transcript of new research
        #{transcript}
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, section, response}
      other -> other
    end
  end
end
