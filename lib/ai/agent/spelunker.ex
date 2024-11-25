defmodule AI.Agent.Spelunker do
  defstruct [
    :ai,
    :opts,
    :symbol,
    :start_file,
    :question,
    :messages,
    :response,
    :requested_tool_calls
  ]

  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the Spelunker Agent. Your job is to *thoroughly* work through maps of code symbols and function calls to *completely* trace paths through the code base.
  You are a code explorer and a graph search, digging through "outlines" (representations of code files as symbols and their relationships) to trace paths through the code base on behalf of the Answers Agent, who interacts with the user.
  You will assist the Answers Agent in answering questions about the code base by following the path from one symbol to another or by identifying files and assembling a call back to a particular symbol.
  Use the tool calls at your disposal to dig through the code base; combine multiple tool calls into a single request to perform them concurrently.
  Use your tools as many times as necessary to ensure that you have the COMPLETE picture. Do NOT respond ambiguously unless you have made multiple attempts to find the answer.
  You will use these outlines to navigate code files, tracing paths through the code in order to assist the Answers Agent in correctly answering the user's questions about the code base.
  To find callers, start with the target symbol and work backwards through the code base, alternating between the search_tool and outline_tool, until you reach a dead end or entry point. Report the paths you discovered.
  To find callees, search for the target symbol and filter based on language-specific semantics (e.g. imports, aliases, etc.) to find all references to the symbol. Report the paths you discovered.
  Your highest priority is to provide COMPLETE and ACCURATE information to the Answers Agent; ensure you have a complete code path before sending your response.
  """

  @tools [
    AI.Tools.Search.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.Outline.spec()
  ]

  def perform(ai, opts) do
    with {:ok, response, _usage} <- build_response(ai, opts) do
      {:ok, response}
    end
  end

  defp build_response(ai, opts) do
    AI.Response.get(ai,
      on_event: &on_event/2,
      max_tokens: @max_tokens,
      model: @model,
      tools: @tools,
      system: @prompt,
      user: """
      The Answers Agent has requested your assistance in tracing a path
      through the code base, beginning with the symbol `#{opts.symbol}` in the
      file `#{opts.start_file}`, in order to discover the answer to this question:
      `#{opts.question}`.
      """
    )
  end

  defp on_event(:tool_call, {"search_tool", %{"query" => query}}) do
    UI.report_step("Searching", query)
  end

  defp on_event(:tool_call, {"list_files_tool", _args}) do
    UI.report_step("Listing files in project")
  end

  defp on_event(:tool_call, {"file_info_tool", %{"file" => file, "question" => question}}) do
    UI.report_step("Considering #{file}", question)
  end

  defp on_event(_, _), do: :ok
end
