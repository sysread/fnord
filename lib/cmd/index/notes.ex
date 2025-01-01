defmodule Cmd.Index.Notes do
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

      with {:ok, consolidated} <- consolidate_saved_notes(idx, original_notes),
           {:ok, fact_checked} <- fact_check_saved_notes(idx, consolidated),
           :ok <- confirm_updated_notes(idx, fact_checked, original_count) do
        save_updated_notes(idx, fact_checked)
      else
        :aborted -> UI.warn("Defragmenting notes", "Aborted at user request")
        error -> UI.warn("Defragmenting notes", inspect(error))
      end
    end
  end

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

  defp confirm_updated_notes(_idx, notes, original_count) do
    new_count = Enum.count(notes)

    difference =
      ((new_count - original_count) / original_count * 100)
      |> Float.round(0)
      |> trunc()
      |> abs()

    IO.puts("# Defragmented Notes")

    notes
    |> Enum.each(fn note ->
      with {:ok, {topic, facts}} <- Store.Project.Note.parse_string(note) do
        IO.puts("\n## #{topic}")

        facts
        |> Enum.map(&"- #{&1}")
        |> Enum.each(&IO.puts/1)
      else
        {:error, :invalid_format} ->
          IO.puts(:stderr, "Invalid note format: #{note}")
          IO.puts(:stderr, "Cancelling defragmentation")
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

  defp validate_notes(notes_string) do
    notes_string
    |> parse_topic_list()
    |> Enum.reduce_while([], fn text, acc ->
      case Store.Project.Note.parse_string(text) do
        {:ok, _parsed} -> {:cont, [text | acc]}
        {:error, :invalid_format} -> {:halt, :invalid_format}
      end
    end)
    |> case do
      :invalid_format -> {:error, :invalid_format}
      notes -> {:ok, notes}
    end
  end

  defp parse_topic_list(input_str) do
    input_str
    |> String.trim("```")
    |> String.trim("'''")
    |> String.trim("\"\"\"")
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end

  # ----------------------------------------------------------------------------
  # Consolidating saved notes
  # ----------------------------------------------------------------------------
  defp consolidate_saved_notes(_idx, []) do
    UI.info("Consolidating prior research", "Nothing to do")
    {:ok, []}
  end

  defp consolidate_saved_notes(_idx, original_notes) do
    original_count = Enum.count(original_notes)
    UI.report_step("Consolidating prior research", "Analyzing #{original_count} notes")

    with args = %{notes: original_notes},
         {:ok, consolidated} <- AI.Agent.NotesConsolidator.get_response(AI.new(), args),
         {:ok, notes} <- validate_notes(consolidated) do
      {:ok, notes}
    end
  end

  # ----------------------------------------------------------------------------
  # Fact-checking
  # ----------------------------------------------------------------------------
  defp fact_check_saved_notes(_idx, []) do
    UI.info("Fact-checking prior research", "Nothing to do")
    {:ok, []}
  end

  defp fact_check_saved_notes(_idx, original_notes) do
    original_count = Enum.count(original_notes)
    UI.report_step("Fact-checking prior research", "Analyzing #{original_count} notes")

    with args = %{notes: original_notes},
         {:ok, consolidated} <- AI.Agent.NotesVerifier.get_response(AI.new(), args),
         {:ok, notes} <- validate_notes(consolidated) do
      {:ok, notes}
    end
  end
end
