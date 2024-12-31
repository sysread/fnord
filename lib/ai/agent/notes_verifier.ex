defmodule AI.Agent.NotesVerifier do
  @model "gpt-4o"
  @max_tokens 128_000
  @prompt """
  You are an AI agent responsible for fact-checking a list of notes.
  You will be presented with a list of individual facts formatted in markdown.
  Facts are defined as a single imperative statement.

  Process:
  1. Use the list_files_tool to get a list of all current files in the project
  2. If the fact includes a file path:
    2.1. Look up the file in the list_files_tool output
    2.2. If the path is no longer valid:
      2.2.1. Use the search_tool to try to find the information in another file
    2.3. Use the file_info_tool to verify the fact (see below)
  3. If the fact does NOT include a file path:
    3.1. Use the search_tool to try to find the information in another file or combination of files
    3.2. Use the file_info_tool to attempt to verify the fact (see below)

  Fact checking with the file_info_tool:
  - Instruct the tool to classify the fact as `proven`, `disproven`, or `inconclusive` (not enough information to prove or disprove)
  - If the fact is `proven`, update the fact to reflect the correct information
  - If the fact is `disproven`, remove the fact
  - If the fact is `inconclusive`, leave the fact as is; this **should** happen often because the fact may have been inferred from multiple files

  Combine as many tool calls as possible to parallelize your work
  - Default concurrency is 8, and is handled by a pool of workers. Go nuts.
  - You could totally do a request to the file_info_tool for EVERY fact at once and let the pool worry about it.

  It is IMPERATIVE that NO FACTUALLY ACCURATE INFORMATION IS LOST.
  If your new list is more than 25% shorter than the original, DOUBLE-CHECK YOUR WORK.
  **If you are unsure, leave the note intact.**

  Respond with the consolidated list of facts as an unordered markdown list.
  Do not include any comments, summary, or explanation - JUST the list.
  """

  @tools [
    AI.Tools.FileInfo.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.Search.spec()
  ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, notes} <- Map.fetch(opts, :notes) do
      question =
        notes
        |> Enum.map(fn note -> "- #{note}" end)
        |> Enum.join("\n")
        |> AI.Util.user_msg()

      AI.Completion.get(ai,
        max_tokens: @max_tokens,
        model: @model,
        tools: @tools,
        messages: [AI.Util.system_msg(@prompt), question]
      )
      |> then(fn {:ok, %{response: response}} ->
        notes =
          response
          |> String.split("\n")
          |> Enum.map(fn line ->
            line
            |> String.trim()
            |> String.trim_leading("-")
            |> String.trim()
          end)
          |> Enum.join("\n")

        {:ok, notes}
      end)
    end
  end
end
