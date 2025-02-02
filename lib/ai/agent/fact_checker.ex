defmodule AI.Agent.FactChecker do
  @model "gpt-4o"
  @max_tokens 60_000

  @prompt """
  #{AI.Util.note_format_prompt()}

  You are the Fact Checker Agent, responsible for confirming, refuting, and correcting facts learned from prior research.

  Your role is to:
  - Examine the notes provided to determine their accuracy.
  - Provide a response that confirms, refutes, or corrects the facts.
  - Use the file's content to support your response.
  - Ensure that the response is accurate and relevant to the query.

  Note that facts may have been learned by examining multiple files.
  Use your tool calls to perform a complete investigation and determine the accuracy of the information.
  If a note mentions a file that does not exist, you should assume that the fact is invalid.

  **IT IS ESSENTIAL THAT NO FACTUAL INFORMATION IS LOST.**

  # Response
  Your response template varies based on your findings:
  - CORRECT: respond with `CONFIRMED:<original note>`
  - CORRECTABLE WITH THE INFORMATION YOU FOUND: respond with `CONFIRMED:<corrected note>`
  - INCORRECT: respond with `REFUTED:<original note>`
  """

  @invalid_format_prompt """
  The fact-checked note was not in the expected format.
  Please correct the format. Respond ONLY with the expected note format.

  The correct format is ALWAYS one of:
  - `CONFIRMED:<original note>`
  - `CONFIRMED:<corrected note>`
  - `REFUTED:<original note>`
  """

  @non_git_tools [
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_diff_branch_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
    AI.Tools.tool_spec!("git_grep_tool"),
    AI.Tools.tool_spec!("git_log_tool"),
    AI.Tools.tool_spec!("git_pickaxe_tool"),
    AI.Tools.tool_spec!("git_show_tool")
  ]

  @tools @non_git_tools ++ @git_tools

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, note} <- Map.fetch(opts, :note),
         {confirmed, refuted} <- fact_check_note(note, ai) do
      {:ok, {confirmed, refuted}}
    else
      :error ->
        {:error, "missing required argument: note"}

      :invalid_format ->
        {:error, "the LLM responded with the incorrect format after 3 attempts"}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp fact_check_note(note, ai) do
    1..3
    |> Enum.reduce_while(nil, fn _attempt, acc ->
      note
      |> get_completion(ai, acc)
      |> process_response()
      |> validate()
      |> case do
        {:ok, {confirmed, refuted}} -> {:halt, {confirmed, refuted}}
        {:error, :invalid_format} -> {:cont, :invalid_format}
      end
    end)
  end

  defp get_completion(note, ai, prior_failure) do
    messages = [
      AI.Util.system_msg(@prompt),
      AI.Util.user_msg(note)
    ]

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
      tools: available_tools(),
      messages: messages
    )
  end

  defp process_response({:ok, %{response: response}}) do
    response
    |> String.split("\n")
    |> Enum.reduce_while({[], []}, fn line, {confirmed, refuted} ->
      line
      |> parse_line
      |> case do
        {:confirmed, note} -> {:cont, {[note | confirmed], refuted}}
        {:refuted, note} -> {:cont, {confirmed, [note | refuted]}}
        {:error, :invalid_format} -> {:halt, {:error, :invalid_format}}
      end
    end)
    |> case do
      {:error, :invalid_format} -> {:error, :invalid_format}
      {confirmed, refuted} -> {:ok, {join(confirmed), join(refuted)}}
    end
  end

  defp parse_line(line) do
    line
    |> String.trim()
    |> String.trim_leading("-")
    |> String.trim()
    |> String.split(":", parts: 2)
    |> case do
      ["CONFIRMED", note] -> {:confirmed, note}
      ["REFUTED", note] -> {:refuted, note}
      _ -> {:error, :invalid_format}
    end
  end

  defp validate({:error, error}), do: {:error, error}

  defp validate({:ok, {confirmed, refuted}}) do
    case AI.Util.validate_notes_string(confirmed) do
      {:ok, _} -> {:ok, {confirmed, refuted}}
      {:error, :invalid_format} -> {:error, :invalid_format}
    end
  end

  defp join({a, b}), do: {join(a), join(b)}
  defp join(notes), do: notes |> Enum.join("\n")

  defp available_tools() do
    if Git.is_git_repo?() do
      @tools
    else
      @non_git_tools
    end
  end
end
