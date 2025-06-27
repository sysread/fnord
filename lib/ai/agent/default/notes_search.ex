defmodule AI.Agent.Default.NotesSearch do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are a specialized assistant for searching notes in the `fnord` project.
  Your task is to find relevant notes based on a search term provided by the LLM that is interacting with the user.
  Respond with the most relevant notes in JSONL format.
  If no relevant notes are found, return an empty JSONL string.
  It is ESSENTIAL that the notes you respond with are unchanged from the original notes.
  Do not include any additional commentary, explanations, or code fences in your response.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, needle} <- Map.fetch(opts, :needle),
         {:ok, notes} <- read_notes() do
      AI.Completion.get(
        model: @model,
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg("""
          # Notes
          ```jsonl
          #{notes}
          ```

          # Search Term
          #{needle}
          """)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_notes do
    Store.DefaultProject.Notes.file_path()
    |> File.read()
  end
end
