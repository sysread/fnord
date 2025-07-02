defmodule AI.Agent.Default.Remembery do
  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are a specialized assistant for searching "memories" in the `fnord` project.
  Your task is to find relevant memories based on a search term provided by the LLM that is interacting with the user.
  Respond with the most relevant memories in JSONL format.
  If no relevant memories are found, return an empty JSONL string.
  It is ESSENTIAL that the memories you respond with are unchanged from the original memories.
  Do not include any additional commentary, explanations, or code fences in your response.
  If nothing matches, respond with an empty string (rather than `[]`, because that's not valid for JSONL).
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, needle} <- Map.fetch(opts, :needle),
         {:ok, memories} <- read_memories() do
      AI.Completion.get(
        model: @model,
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg("""
          # Memories
          ```jsonl
          #{memories}
          ```

          # Search Term
          #{needle}
          """)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, parse_response(response)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_memories do
    Store.DefaultProject.Memories.file_path()
    |> File.read()
  end

  defp parse_response(response) do
    response
    |> String.split("\n", trim: true)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(&Jason.decode!/1)
  end
end
