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
            help: "Number of concurrent workers to use",
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
  def run(opts) do
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

    with {:ok, consolidated} <- consolidate_saved_notes(notes),
         {:ok, confirmed, refuted} <- fact_check_saved_notes(consolidated),
         :ok <- confirm_updated_notes(confirmed, refuted, count) do
      save_updated_notes(project, confirmed)
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
  @consolidation_batch_size 2

  @type note :: String.t()
  @type batch :: [note]

  defp consolidate_saved_notes([]) do
    UI.info("Consolidating prior research", "Nothing to do")
    {:ok, []}
  end

  defp consolidate_saved_notes(original_notes) do
    count = Enum.count(original_notes)
    batch_count = count_batches(count)

    UI.report_step("Consolidating prior research")
    UI.progress_bar_start(:consolidation, "Tasks", batch_count)

    with {:ok, result} <- original_notes |> consolidate_notes |> AI.Util.validate_notes_string() do
      UI.report_step(
        "Consolidated notes",
        "Consolidated #{count} notes into #{Enum.count(result)}"
      )

      {:ok, result}
    end
  end

  defp consolidate_notes([note]) when is_binary(note), do: note

  defp consolidate_notes(notes) do
    notes
    |> Enum.chunk_every(@consolidation_batch_size)
    |> consolidate_notes_batches()
    |> consolidate_notes()
  end

  defp consolidate_notes_batches(notes_batches) do
    ai = AI.new()

    {:ok, queue} =
      Queue.start_link(fn batch ->
        result =
          with {:ok, note} <- AI.Agent.NotesConsolidator.get_response(ai, %{notes: batch}) do
            note
          else
            # Return the original notes unchanged in case of an error
            error ->
              UI.error("Error consolidating notes", inspect(error))
              Enum.join(batch, "\n")
          end

        UI.progress_bar_update(:consolidation)

        result
      end)

    notes_batches
    |> Queue.map(queue)
    |> then(fn notes ->
      Queue.shutdown(queue)
      Queue.join(queue)
      notes
    end)
  end

  defp count_batches(notes_count), do: count_batches(notes_count, 0)

  defp count_batches(1, acc), do: acc

  defp count_batches(notes_count, acc) do
    batches =
      1..notes_count
      |> Enum.chunk_every(@consolidation_batch_size)
      |> Enum.count()

    count_batches(batches, acc + batches)
  end

  # ----------------------------------------------------------------------------
  # Fact-checking
  # ----------------------------------------------------------------------------
  @spec fact_check_saved_notes([note]) ::
          {:ok, [note], [note]}

  defp fact_check_saved_notes([]) do
    UI.info("Fact-checking prior research", "Nothing to do")
    {:ok, []}
  end

  defp fact_check_saved_notes(notes) do
    count = Enum.count(notes)

    {:ok, queue} =
      Queue.start_link(fn note ->
        result = fact_check_saved_note(note)
        UI.progress_bar_update(:fact_checking)
        result
      end)

    UI.progress_bar_start(:fact_checking, "Verifying prior research", count)

    tasks = notes |> Enum.map(&Queue.queue(queue, &1))

    # queue files
    {confirmed, refuted} =
      tasks
      |> Task.await_many(5 * 60 * 1000)
      |> Enum.reduce({[], []}, fn
        {:ok, confirmed, refuted}, {acc_confirmed, acc_refuted} ->
          {
            confirmed ++ acc_confirmed,
            [refuted | acc_refuted]
          }

        _, acc ->
          acc
      end)

    # wait on queue to complete
    Queue.shutdown(queue)
    Queue.join(queue)

    {:ok, confirmed, refuted}
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
  defp confirm_updated_notes([], [], 0), do: :no_change

  defp confirm_updated_notes(confirmed, refuted, original_count) do
    new_count = Enum.count(confirmed)
    change = abs(new_count - original_count)

    difference =
      case change do
        0 ->
          0

        _ ->
          (new_count / original_count * 100)
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

  defp save_updated_notes(project, notes) do
    count = Enum.count(notes)

    UI.report_step("Saving updated notes")

    {:ok, queue} =
      Queue.start_link(fn text ->
        project
        |> Store.Project.Note.new()
        |> Store.Project.Note.write(text)
      end)

    UI.report_step("Clearing old notes")
    Store.Project.reset_notes(project)

    # queue files
    UI.report_step("Saving consolidated notes")
    Enum.each(notes, &Queue.queue(queue, &1))

    # wait on queue to complete
    Queue.shutdown(queue)
    Queue.join(queue)

    UI.info("#{count} notes saved")

    :ok
  end

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
