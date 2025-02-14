defmodule AI.Agent.Archivist do
  @model AI.Model.balanced()

  @prompt """
  You are the Archivist Agent.
  You are responsible for reading, organizing, and assimilating prior research.
  You will be provided with a query from the Coordinating AI Agent.
  Reorganize the information, optimizing it for relevance to the current query.
  Keep your responses as concise as possible to maximize information density in your response.
  """

  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, query} <- Map.fetch(opts, :query),
         {:ok, %{response: response}} <- build_response(ai, query) do
      {:ok, response}
    end
  end

  defp build_response(ai, query) do
    AI.Accumulator.get_response(ai,
      model: @model,
      prompt: @prompt,
      question: query,
      input: get_notes(query)
    )
  end

  defp get_notes(query) do
    Store.get_project()
    |> Store.Project.search_notes(query)
    |> Enum.reduce([], fn {_score, note}, acc ->
      with {:ok, text} <- Store.Project.Note.read_note(note) do
        [text | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
