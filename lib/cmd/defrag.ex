defmodule Cmd.Defrag do
  @behaviour Cmd

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @impl Cmd
  def spec do
    [
      defrag: [
        name: "defrag",
        about: "Consolidate and fact-check saved notes",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Limits the number of concurrent OpenAI requests",
            parser: :integer,
            default: Cmd.default_workers()
          ]
        ],
        flags: [
          quiet: [
            long: "--quiet",
            short: "-Q",
            help: "Suppress interactive output; automatically enabled when executed in a pipe",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _unknown) do
    project_name = Map.get(opts, :project)
    Application.put_env(:fnord, :project, project_name)

    project_name
    |> Store.get_project()
    |> defrag()
  end

  # -----------------------------------------------------------------------------
  # Notes clean up
  # -----------------------------------------------------------------------------
  defp defrag(project) do
    notes = get_notes(project)
    count = Enum.count(notes)

    UI.info("Project", project.name)
    UI.info("Workers", Application.get_env(:fnord, :workers) |> to_string())
    UI.info(" Topics", to_string(count))

    with {:ok, confirmed, refuted} <- fact_check_saved_notes(notes),
         {:ok, consolidated} <- consolidate_saved_notes(confirmed),
         :ok <- confirm_updated_notes(consolidated, refuted, count) do
      save_updated_notes(project, consolidated)
    else
      {:error, :invalid_format} ->
        UI.error("Error defragmenting notes", "Invalid note format")

      :no_change ->
        UI.info("Defragmenting notes", "No changes needed")

      :aborted ->
        UI.warn("Defragmenting notes", "Aborted at user request")
    end
  end

  # ----------------------------------------------------------------------------
  # Consolidating saved notes
  # ----------------------------------------------------------------------------
  @type note :: String.t()

  @spec consolidate_saved_notes([note]) :: {:ok, [note]} | {:error, :invalid_format}
  defp consolidate_saved_notes([]) do
    UI.info("Consolidating prior research", "Nothing to do")
    {:ok, []}
  end

  defp consolidate_saved_notes(original_notes) do
    ai = AI.new()
    count = Enum.count(original_notes)
    UI.progress_bar_start(:consolidation, "Consolidating #{count} notes", 1)

    with {:ok, note} <- AI.Agent.NotesConsolidator.get_response(ai, %{notes: original_notes}),
         {:ok, result} <- AI.Util.validate_notes_string(note) do
      new_count = Enum.count(result)
      UI.progress_bar_update(:consolidation)
      UI.report_step("Consolidated", "from #{count} to #{new_count}")
      {:ok, result}
    end
  end

  # ----------------------------------------------------------------------------
  # Fact-checking
  # ----------------------------------------------------------------------------
  @spec fact_check_saved_notes([note]) :: {:ok, [note], [note]}
  defp fact_check_saved_notes([]) do
    UI.info("Fact-checking prior research", "Nothing to do")
    {:ok, [], []}
  end

  defp fact_check_saved_notes(notes) do
    notes
    |> UI.async_stream(&fact_check_saved_note/1, "Fact-checking notes")
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, confirmed, refuted}}, {acc_confirmed, acc_refuted} ->
        {
          confirmed ++ acc_confirmed,
          [refuted | acc_refuted]
        }

      _, acc ->
        acc
    end)
    |> then(fn {confirmed, refuted} ->
      {:ok, confirmed, refuted}
    end)
  end

  @spec fact_check_saved_note(note) ::
          {:ok, note, note}
          | {:error, String.t()}
          | {:error, :invalid_format}
  defp fact_check_saved_note(note) do
    ai = AI.new()
    args = %{note: note}

    with {:ok, {confirmed, refuted}} <- AI.Agent.FactChecker.get_response(ai, args),
         {:ok, validated} <- AI.Util.validate_notes_string(confirmed) do
      if refuted != "" do
        UI.report_step("Refuted prior research", refuted)
      end

      {:ok, validated, refuted}
    end
  end

  # -----------------------------------------------------------------------------
  # Confirmation and validation
  # -----------------------------------------------------------------------------
  @spec confirm_updated_notes([note], [note], non_neg_integer) ::
          :ok
          | :aborted
          | :no_change
  defp confirm_updated_notes([], [], 0), do: :no_change

  defp confirm_updated_notes(confirmed, refuted, original_count) do
    new_count = Enum.count(confirmed)
    change = abs(original_count - new_count)

    difference =
      case change do
        0 ->
          0

        _ ->
          (change / original_count * 100)
          |> Float.round(0)
          |> trunc()
      end

    IO.puts("""

    /-----------------------------------------------------------
    | Refuted Notes
    \\-----------------------------------------------------------

    """)

    refuted
    |> Enum.each(fn note ->
      note = String.trim(note)

      if note != "" do
        IO.puts(note)
      end
    end)

    IO.puts("""

    /-----------------------------------------------------------
    | Confirmed Notes
    \\-----------------------------------------------------------

    """)

    confirmed
    |> Enum.each(fn note ->
      note
      |> note_to_string()
      |> IO.puts()

      IO.puts("")
    end)

    IO.puts("""

    /-----------------------------------------------------------
    | There is a #{difference}% change in note count:
    |   * Original: #{original_count}
    |   *  Updated: #{new_count}
    \\-----------------------------------------------------------

    """)

    if UI.confirm("Replace your saved notes with the updated list?") do
      :ok
    else
      :aborted
    end
  end

  # -----------------------------------------------------------------------------
  # Retrieval and saving
  # -----------------------------------------------------------------------------
  @spec get_notes(Store.Project.t()) :: [note]
  defp get_notes(project) do
    project
    |> Store.Project.notes()
    |> Enum.reduce([], fn note, acc ->
      with {:ok, text} <- Store.Project.Note.read_note(note) do
        [text | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  @spec save_updated_notes(Store.Project.t(), [note]) :: :ok
  defp save_updated_notes(project, notes) do
    count = Enum.count(notes)

    UI.report_step("Saving updated notes")

    UI.report_step("  - Clearing old notes")
    Store.Project.reset_notes(project)

    UI.report_step("  - Saving consolidated notes")

    notes
    |> UI.async_stream(
      fn text ->
        project
        |> Store.Project.Note.new()
        |> Store.Project.Note.write(text)
      end,
      "Saving notes"
    )
    |> Enum.to_list()

    UI.info("  - #{count} notes saved")

    :ok
  end

  @spec note_to_string(note) :: String.t()
  defp note_to_string(note) do
    with {:ok, {topic, facts}} <- Store.Project.Note.parse_string(note) do
      facts
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")
      |> then(fn str -> "## #{topic}\n#{str}" end)
    else
      {:error, :invalid_format, type} ->
        """
        WARNING - Invalid note format - Improperly formatted #{to_string(type)}:
        #{note}
        """
    end
    |> String.trim()
  end
end
