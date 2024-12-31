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

  It is IMPERATIVE that NO INFORMATION IS LOST.
  If your new list is more than 25% shorter than the original, DOUBLE-CHECK YOUR WORK.
  **If you are unsure, leave the note intact.**

  Respond with the consolidated list of facts as an unordered markdown list.
  Do not include any comments, summary, or explanation - JUST the list.
  """

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
