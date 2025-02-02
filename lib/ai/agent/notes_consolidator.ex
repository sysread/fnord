defmodule AI.Agent.NotesConsolidator do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  #{AI.Util.note_format_prompt()}

  You are an AI agent responsible for analyzing a list of facts and consolidating them.
  You will be presented with a mess of individual facts and documents.
  Input may include mixed formats. It is your job to organize them into a coherent structure.
  Break down all the information into discrete facts, then reorganize them by topic.
  Your goal is to reorgnaize facts under a small number of broad topics.
  Try to reorganize and categorize all of the facts under a maximum of 20 topics.
  If required, broaden the scope of topics to make this possible.
  - DO *combine* ALL of the facts from similar topics under a SINGLE topic.
  - DO *merge* IDENTICAL facts.
  - DO NOT *merge* facts that are similar but not identical.
  **It is ESSENTIAL that no facts are lost.**
  """

  @invalid_format_prompt """
  The fact-checked note was not in the expected format.
  Please correct the format. Respond ONLY with the expected note format.
  """

  @invalid_format_error "the LLM responded with the incorrect format after 3 attempts"
  @missing_arg_error "missing required argument: notes"

  @type note :: String.t()
  @type ai :: AI.t()

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, notes} <- Map.fetch(opts, :notes),
         {:ok, notes} <- consolidate_notes(notes, ai) do
      {:ok, notes}
    else
      {:error, :invalid_format} -> {:error, @invalid_format_error}
      :error -> {:error, @missing_arg_error}
    end
  end

  @spec consolidate_notes([note], ai) :: {:ok, note} | {:error, :invalid_format}
  defp consolidate_notes(notes, ai) do
    1..3
    |> Enum.reduce_while(nil, fn _attempt, acc ->
      notes
      |> get_completion(ai, acc)
      |> process_response()
      |> AI.Util.validate_notes_string()
      |> case do
        {:ok, notes} -> {:halt, Enum.join(notes, "\n")}
        {:error, :invalid_format} -> {:cont, :invalid_format}
      end
    end)
    |> case do
      :invalid_format -> {:error, :invalid_format}
      valid_notes when is_binary(valid_notes) -> {:ok, valid_notes}
    end
  end

  @spec get_completion([note], ai, nil | :invalid_format) :: note
  defp get_completion(notes, ai, prior_failure) do
    notes_msg = Enum.join(notes, "\n")
    messages = [AI.Util.system_msg(@prompt), AI.Util.user_msg(notes_msg)]

    messages =
      case prior_failure do
        nil -> messages
        :invalid_format -> messages ++ [AI.Util.system_msg(@invalid_format_prompt)]
      end

    AI.Completion.get(ai,
      log_msgs: false,
      log_tool_calls: false,
      use_planner: false,
      max_tokens: @max_tokens,
      model: @model,
      messages: messages
    )
    |> then(fn {:ok, %{response: response}} ->
      response
    end)
  end

  @spec process_response(note) :: note
  defp process_response(response) do
    response
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.trim_leading("-")
      |> String.trim()
    end)
    |> Enum.join("\n")
  end
end
