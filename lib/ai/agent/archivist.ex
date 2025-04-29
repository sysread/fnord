defmodule AI.Agent.Archivist do
  # This is important, because balanced() has a 1m token context window, and we
  # are stuffing a LOT of content into it: both the conversation transcript as
  # well as ALL prior research notes.
  @model AI.Model.balanced()

  @prompt """
  You are the Archivist AI Agent.
  The Orchestrating Agent has performed research to answer the user's question.
  You will be provided with a transcript of the conversation, including the user's query and the research performed by the Orchestrating Agent.
  You will organize and file the facts discovered during the research for future reference.
  Your saved notes will be used in future responses to more accurately answer the user's question.

  Many code bases are long-lived, with multiple languages, changes to terminology that are inconsistently applied, and ambiguous or stale documentation.
  Rather than discovering these inconsistencies and ambiguities every time the user asks a question, you can help the Orchestrating Agent by tracking this information so it doesn't trip us up in the future.

  Some important types of information that you should track include:
  - ambiguities in phrasing:
    - inconsistent phrasing
    - components or concepts with names that are similar to other components
    - components or concepts that are referenced by multiple names
    - components or concepts that have unexpected names that do not match their behavior
    - changes in terminology or naming conventions over time
  - inaccurate documentation or comments; this will help prevent us from being misled by stale or incorrect information in the future
  - the purpose of a file, component, or concept
  - relationships between files, components, or concepts
  - the location or single source of truth for a concept
  - data flow between components and application boundaries
  - organization of different apps within the code base, and how they interconnect
  - organization of components, especially if they are not organized in a way that is easy to understand
  - anything else that you think might might be useful or prevent us from getting tripped up in the future
  - which research strategies worked well
  - which research strategies did not work well

  Read the transcript and identify ALL facts that were discovered about the code base.
  Include facts even if (*especially* if) they are unrelated to the user's query.

  Read the existing research notes and incorporate the new research into them:
  - Remove any facts that were disproven by the new research transcript
  - Update any facts that were changed or clarified by the new research transcript
  - Add any new facts that were discovered in the new research transcript
  - Do not lose existing facts that were NOT disproven by the new research transcript
  - Consolidate and reorganize as appropriate to minimize duplication and character count
  - Organize the facts by topic
  - Use markdown headers for each topic, followed by a list of facts

  Respond ONLY with the updated research notes, organized as a markdown file, without preamble or explanation, in markdown format, WITHOUT fences.
  Just the notes text, my dude.
  """

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, transcript} <- Map.fetch(opts, :transcript),
         {:ok, old_notes} <- get_notes(),
         {:ok, %{response: response}} <- build_response(ai, transcript, old_notes),
         :ok <- Store.Project.Notes.write(response) do
      {:ok, response}
    end
  end

  defp build_response(ai, transcript, old_notes) do
    input = """
    # NEW RESEARCH TRANSCRIPT
    #{transcript}

    # EXISTING RESEARCH NOTES
    #{old_notes}
    """

    AI.Accumulator.get_response(ai,
      model: @model,
      prompt: @prompt,
      input: input,
      question: "Organize and file the facts discovered during the research for future reference."
    )
  end

  defp get_notes() do
    case Store.Project.Notes.read() do
      {:ok, notes} -> {:ok, notes}
      {:error, :no_notes} -> {:ok, "<no research has been conducted yet>"}
    end
  end
end
