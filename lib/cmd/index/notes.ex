defmodule Cmd.Index.Notes do
  @consolidation_batch_size 4

  # ----------------------------------------------------------------------------
  # Options
  # ----------------------------------------------------------------------------
  defp defrag?(idx), do: Map.get(idx.opts, :defrag_notes, false)

  # -----------------------------------------------------------------------------
  # Notes clean up
  # -----------------------------------------------------------------------------
  def defrag(idx) do
    if defrag?(idx) do
      original_notes = get_notes(idx)
      original_count = Enum.count(original_notes)

      with {:ok, consolidated} <- consolidate_saved_notes(original_notes),
           {:ok, fact_checked} <- fact_check_saved_notes(consolidated),
           :ok <- confirm_updated_notes(fact_checked, original_count) do
        save_updated_notes(idx, fact_checked)
      else
        :no_change -> UI.info("Defragmenting notes", "No changes needed")
        :aborted -> UI.warn("Defragmenting notes", "Aborted at user request")
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Consolidating saved notes
  # ----------------------------------------------------------------------------
  @type note :: String.t()
  @type batch :: [note]

  @spec consolidate_saved_notes([note]) :: {:ok, [note]}
  defp consolidate_saved_notes([]) do
    UI.info("Consolidating prior research", "Nothing to do")
    {:ok, []}
  end

  defp consolidate_saved_notes(original_notes) do
    count = Enum.count(original_notes)

    UI.report_step("Consolidating prior research")

    Cmd.Index.UI.progress_bar_start(:consolidation, "Tasks", count)

    {:ok, result} =
      original_notes
      |> consolidate_notes()
      |> AI.Util.validate_notes_string()

    UI.report_step("Consolidated notes", "Consolidated #{count} notes into #{Enum.count(result)}")

    {:ok, result}
  end

  @spec consolidate_notes([note]) :: note
  defp consolidate_notes([note]) when is_binary(note), do: note

  defp consolidate_notes(notes) do
    notes
    |> Enum.chunk_every(@consolidation_batch_size)
    |> consolidate_notes_batches()
    |> consolidate_notes()
  end

  @spec consolidate_notes_batches([batch]) :: [note]
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

        1..Enum.count(batch)
        |> Enum.each(fn _ ->
          Cmd.Index.UI.progress_bar_update(:consolidation)
        end)

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

  # ----------------------------------------------------------------------------
  # Fact-checking
  # ----------------------------------------------------------------------------
  @spec fact_check_saved_notes([note]) :: {:ok, [note]}
  defp fact_check_saved_notes([]) do
    UI.info("Fact-checking prior research", "Nothing to do")
    {:ok, []}
  end

  defp fact_check_saved_notes(original_notes) do
    original_count = Enum.count(original_notes)

    UI.report_step("Fact-checking prior research", "Analyzing #{original_count} notes")
    Cmd.Index.UI.progress_bar_start(:fact_checking, "Verifying prior research", original_count)
    {:ok, queue} = Queue.start_link(&fact_check_saved_note(&1))

    # queue files
    confirmed =
      original_notes
      |> Queue.map(queue)
      |> Enum.reduce([], fn
        {:ok, confirmed}, acc -> acc ++ confirmed
        _, acc -> acc
      end)

    # wait on queue to complete
    Queue.shutdown(queue)
    Queue.join(queue)

    {:ok, confirmed}
  end

  @spec fact_check_saved_note(note) :: {:ok, String.t()} | {:error, any}
  defp fact_check_saved_note(note) do
    ai = AI.new()
    args = %{note: note}

    with {:ok, {confirmed, refuted}} <- AI.Agent.FactChecker.get_response(ai, args),
         {:ok, validated} <- AI.Util.validate_notes_string(confirmed) do
      Cmd.Index.UI.progress_bar_update(:fact_checking)

      if refuted != "" do
        UI.report_step("Refuted prior research", refuted)
      end

      {:ok, validated}
    end
  end

  # -----------------------------------------------------------------------------
  # Retrieval and saving
  # -----------------------------------------------------------------------------
  defp get_notes(idx) do
    idx.project
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

  defp save_updated_notes(idx, notes) do
    count = Enum.count(notes)

    Cmd.Index.UI.spin("Updating notes", fn ->
      {:ok, queue} =
        Queue.start_link(fn text ->
          idx.project
          |> Store.Project.Note.new()
          |> Store.Project.Note.write(text)
        end)

      UI.report_step("Clearing old notes")
      Store.Project.reset_notes(idx.project)

      # queue files
      UI.report_step("Saving consolidated notes")
      Enum.each(notes, &Queue.queue(queue, &1))

      # wait on queue to complete
      Queue.shutdown(queue)
      Queue.join(queue)

      {"#{count} notes saved", :ok}
    end)

    UI.info("Notes saved.")
  end

  # -----------------------------------------------------------------------------
  # Confirmation and validation
  # -----------------------------------------------------------------------------
  defp confirm_updated_notes([], 0), do: :no_change

  defp confirm_updated_notes(notes, original_count) do
    new_count = Enum.count(notes)
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

    IO.puts("# Defragmented Notes")

    notes
    |> Enum.each(fn note ->
      with {:ok, {topic, facts}} <- Store.Project.Note.parse_string(note) do
        IO.puts("\n## #{topic}")

        facts
        |> Enum.map(&"- #{&1}")
        |> Enum.each(&IO.puts/1)
      else
        {:error, :invalid_format, type} ->
          IO.puts(:stderr, "")

          IO.puts("""
          WARNING - Invalid note format - Improperly formatted #{to_string(type)}:

          ```
          #{note}
          ```
          """)
      end
    end)

    IO.puts("""

    /-----------------------------------------------------------
    | There is a #{difference}% change in note count:
    |   * Original: #{original_count}
    |   *  Updated: #{new_count}
    \-----------------------------------------------------------

    """)

    if UI.confirm("Replace your saved notes with the updated list?") do
      :ok
    else
      :aborted
    end
  end
end
