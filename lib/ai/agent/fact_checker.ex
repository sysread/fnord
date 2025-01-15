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
  Note that the notes_search_tool is available for your use, with some caveats:
  - It may be useful to cross-reference the notes you are investigating against other similar notes from other research sessions, particularly when dealing with information from multiple files.
  - The notes database is where the facts being investigated came from, so treat it as an **unconfirmed source**.

  **IT IS ESSENTIAL THAT NO FACTUAL INFORMATION IS LOST.**

  # Response
  Your response template varies based on your findings:
  - CORRECT: respond with `OK:<original note>`
  - CORRECTABLE WITH THE INFORMATION YOU FOUND: respond with `OK:<corrected note>`
  - INCORRECT: respond with `ERROR:<original note>`
  """

  @invalid_format_prompt """
  The fact-checked note was not in the expected format.
  Please correct the format. Respond ONLY with the expected note format.

  The correct format is ALWAYS one of:
  - `OK:<original note>`
  - `OK:<corrected note>`
  - `ERROR:<original note>`
  """

  @non_git_tools [
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_spelunker_tool"),
    AI.Tools.tool_spec!("notes_search_tool")
  ]

  @git_tools [
    AI.Tools.tool_spec!("git_diff_branch_tool"),
    AI.Tools.tool_spec!("git_list_branches_tool"),
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

  defp fact_check_note(note, ai) do
    1..3
    |> Enum.reduce_while(nil, fn _attempt, acc ->
      {confirmed, refuted} = note |> get_completion(ai, acc) |> process_response()

      case validate_result(confirmed) do
        {:ok, notes} -> {:halt, {Enum.join(notes, "\n"), refuted}}
        {:error, :invalid_format} -> {:cont, :invalid_format}
      end
    end)
  end

  defp validate_result(note) do
    AI.Util.validate_notes_string(note)
  end

  defp get_completion(note, ai, prior_failure) do
    messages = [AI.Util.system_msg(@prompt), AI.Util.user_msg(note)]

    messages =
      case prior_failure do
        nil -> messages
        :invalid_format -> messages ++ [AI.Util.system_msg(@invalid_format_prompt)]
      end

    AI.Completion.get(ai,
      log_msgs: false,
      log_tool_calls: false,
      log_tool_call_results: false,
      use_planner: false,
      max_tokens: @max_tokens,
      model: @model,
      tools: available_tools(),
      messages: messages
    )
    |> then(fn {:ok, %{response: response}} ->
      response
    end)
  end

  defp process_response(response) do
    response
    |> String.split("\n")
    |> Enum.reduce({[], []}, fn line, {confirmed, refuted} ->
      line
      |> String.trim()
      |> String.trim_leading("-")
      |> String.trim()
      |> String.split(":", parts: 2)
      |> case do
        ["OK", note] -> {[note | confirmed], refuted}
        ["ERROR", _] -> {confirmed, [line | refuted]}
        other -> raise "Unexpected response: #{inspect(other)}"
      end
    end)
    |> then(fn {confirmed, refuted} ->
      {
        Enum.join(confirmed, "\n"),
        Enum.join(refuted, "\n")
      }
    end)
  end

  defp available_tools() do
    if Git.is_git_repo?() do
      @tools
    else
      @non_git_tools
    end
  end
end
