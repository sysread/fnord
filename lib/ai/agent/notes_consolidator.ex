defmodule AI.Agent.NotesConsolidator do
  @model "gpt-4o"
  @max_tokens 128_000
  @prompt """
  You are an AI agent responsible for analyzing a list of facts and de-duplicating them.
  You will be presented with a list of individual facts formatted in markdown.
  Facts are defined as a single imperative statement.

  Analyze the list of facts and consolidate duplicates:
  - Facts are considered duplicates when:
    - They differ ONLY in phrasing or formatting
    - One contains a subset of the information in the other
    - Minor details are additive
  - Combine duplicate facts into a single fact, retaining all information from both facts
  - Combined facts ALWAYS incorporate all distinct elements of both facts
  - Take care not to lose ANY DETAILS from the original list
    - This cannot be emphasized enough. DO NOT LOSE INFORMATION.
    - It's much better to leave a fact in its original form than to lose information

  Fact-check each piece of information you intend to retain:
    - If the information is obviously junk or a placeholder (.e.g "Lorem Ipsum", "TBD", or "???"), remove the fact
    - Combine as many tool calls as possible to parallelize your work
      - Default concurrency is 8, and is handled by a pool of workers. Go nuts.
      - You could totally do a request to the file_info_tool for EVERY fact at once and let the pool worry about it.
    - **list_files_tool:**
      - Confirm that the file paths referenced in a fact exist
      - Correct obvious typos in file paths
      - If there is no clear match for the file path, go ahead and remove the fact
    - **file_info_tool:**
      - Use when the fact contains a file path or you identified a likely path with the list_files_tool or search_tool
      - Ask the file_info_tool to classify the fact as `proven`, `disproven`, or `inconclusive` (not enough information to prove or disprove)
      - Based on the response:
        - `proven` -> update the fact to correct iut
        - `disproven` -> remove the fact
        - `inconclusive` -> leave the fact as is
          - This happens often! Because the fact may be an inference from multiple files.
    - **search_tool:**
      - Use to try and identify the source of the information if the fact does NOT contain a file path
      - Returns a summary of the file, which you can sometimes use to confirm the fact without a separate trip to to file_info_tool

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
