defmodule AI.Agent.NotesConsolidator do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  #{AI.Util.note_format_prompt()}
  #
  You are an AI agent responsible for analyzing a list of facts and consolidating them.
  You will be presented with a mess of individual facts and documents.
  Input may include mixed formats. It is your job to organize them into a coherent structure.
  Break down all the information into discrete facts, then reorganize them by topic.
  Combine IDENTICAL facts.
  **It is ESSENTIAL that no information is lost.**
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
        |> Enum.join("\n-----\n")
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
