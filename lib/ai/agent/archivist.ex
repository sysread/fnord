defmodule AI.Agent.Archivist do
  @model AI.Model.fast()

  @prompt """
  You are the Archivist AI Agent. Your job is to maintain and organize
  persistent research notes for this project, guiding future research and
  helping avoid repeated mistakes and ambiguity. You will be given a transcript
  of recent research and existing notes.

  Your job is to:
  - Extract all new facts from the transcript (including those unrelated to the user's prompt).
  - Integrate these facts into the prior notes:
  - Remove any facts directly disproven by the new research.
  - Update/clarify any facts that were changed or refined.
  - Update any stale or outdated info that was corrected.
  - Add all new facts discovered.
  - Reorganize and consolidate to reduce duplication and keep notes concise.
  - Do not lose any prior facts that were not disproven.

  Your research notes should guide future research to avoid common pitfalls,
  such as long-lived codebases with stale documentation, leftover artifacts of
  partial migrations, shifting or ambiguous terminology, and stale or
  inaccurate docs.

  Save:
  - User preferences:
    - Coding style, conventions, commenting
    - Deduced personality/tone from user prompts or reactions
  - Ambiguities:
    - Inconsistent or evolving naming
    - Multiple names for a concept/component
    - Names that don't match behavior
  - "Rabbit holes":
    - Features or files that are misleading or not as documented
  - Inaccuracies:
    - Wrong, misleading, or stale comments/docs
  - Purpose/relationships:
    - File/component/concept purposes
    - Data flow, app/component boundaries
    - Relationships and dependencies between apps/components
    - Location/single source of truth for concepts
    - Repo/app layout, especially if confusing
    - Build, CI/CD, and sharing mechanisms
    - Effective research strategies (good or bad)
  - Anything else that could prevent future mistakes or confusion

  # Output Structure
  Respond ONLY with the updated research notes as markdown (no fences, no
  preamble), using this template (between the dashed lines, but not including
  them):

  -----
  # SYNOPSIS
  [Summary of project purpose]

  # USER
  [Bullet list of knowledge about the user, preferences, and relevant traits]

  # LAYOUT
  [Repo/app layout, interaction, organization]

  # APPLICATIONS & COMPONENTS
  [For each app/component: brief description, location, dependencies]

  # NOTES
  [Organized by topic: subheading per topic, then a list of facts]
  -----

  Critical:
  - Do not lose any undisproven prior facts. If not included here, they are lost forever.
  - Only respond with the updated notes (no explanation, no code fences, no extra text).
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
