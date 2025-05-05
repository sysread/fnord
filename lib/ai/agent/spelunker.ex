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

  @model AI.Model.balanced()

  @prompt """
  You are the Spelunker Agent. Your job is to *thoroughly* work through maps of code symbols and function calls to *completely* trace paths through the code base.
  You are a code explorer and a graph search, digging through "outlines" (representations of code files as symbols and their relationships) to trace paths through the code base on behalf of the Answers Agent, who interacts with the user.
  You will assist the Answers Agent in answering questions about the code base by following the path from one symbol to another or by identifying files and assembling a call back to a particular symbol.
  Use the tool calls at your disposal to dig through the code base; combine multiple tool calls into a single request to perform them concurrently.
  Use your tools as many times as necessary to ensure that you have the COMPLETE picture. Do NOT respond ambiguously unless you have made multiple attempts to find the answer.
  You will use these outlines to navigate code files, tracing paths through the code in order to assist the Answers Agent in correctly answering the user's questions about the code base.
  To find callers, start with the target symbol and work backwards through the code base, alternating between the file_search_tool and file_outline_tool, until you reach a dead end or entry point. Report the paths you discovered.
  To find callees, search for the target symbol and filter based on language-specific semantics (e.g. imports, aliases, etc.) to find all references to the symbol. Report the paths you discovered.
  Your highest priority is to provide COMPLETE and ACCURATE information to the Answers Agent; ensure you have a complete code path before sending your response.
  """

  @tools [
    AI.Tools.tool_spec!("file_search_tool"),
    AI.Tools.tool_spec!("file_list_tool"),
    AI.Tools.tool_spec!("file_info_tool"),
    AI.Tools.tool_spec!("file_contents_tool"),
    AI.Tools.tool_spec!("file_outline_tool")
  ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, %{response: response}} <- build_response(ai, opts) do
      {:ok, response}
    else
      {:error, %{response: response}} -> {:error, response}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp build_response(ai, opts) do
    AI.Completion.get(ai,
      model: @model,
      tools: @tools,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        The Answers Agent has requested your assistance in tracing a path
        through the code base, beginning with the symbol `#{opts.symbol}` in
        the file `#{opts.start_file}`, in order to discover the answer to this
        question: `#{opts.question}`.
        """)
      ]
    )
  end
end
