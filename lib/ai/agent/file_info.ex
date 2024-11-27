defmodule AI.Agent.FileInfo do
  @model "gpt-4o-mini"

  # It's actually 128k for this model, but this gives us a little bit of
  # wiggle room in case the tokenizer we are using falls behind.
  @max_tokens 100_000

  @prompt """
  You are an AI agent who is responsible for answering questions about a file's
  contents. The AI search agent will request specific details about a file. Use
  your tools as appropriate to provide the most accurate and relevant answers
  to the search agent's questions.
  """

  @tools [
    AI.Tools.GitShow.spec(),
    AI.Tools.GitPickaxe.spec()
  ]

  def get_response(ai, file, question, content) do
    question = """
    File: #{file}
    Question: #{question}
    """

    AI.Accumulator.get_response(ai,
      max_tokens: @max_tokens,
      model: @model,
      tools: @tools,
      prompt: @prompt,
      input: content,
      question: question,
      on_event: &on_event/2
    )
  end

  defp on_event(:tool_call, {"git_show_tool", %{"sha" => sha}}) do
    UI.report_step("[file_info] Inspecting commit", sha)
  end

  defp on_event(:tool_call, {"git_pickaxe_tool", %{"regex" => regex}}) do
    UI.report_step("[file_info] Archaeologizing", regex)
  end

  defp on_event(_, _), do: :ok
end
