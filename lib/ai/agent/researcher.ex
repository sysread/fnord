defmodule AI.Agent.Researcher do
  use Agent

  @model AI.Model.balanced()

  @research_tool_prompt """
  If your research results in more questions, spin off research_tool tool calls
  as necessary, rather than going down those rabbit holes yourself. That helps
  to ensure that your own task stays focused and you don't fill your context
  window with information that may not be pertinent to *your* task, which can
  result in hallucinations. This will help you to provide the most effective
  response.
  """

  @prompt """
  You are an AI agent who performs research on behalf of the Coordinating Agent.
  They will provide you with a research task.
  You are to proactively use your tools to gather information about the code base.

  Many code bases are complex and contain legacy code, so you will need to make
  clever use of your tools to gather the information you need. Take special
  care to identify ambiguities in terminology, unexpected dependencies,
  oddities of code structure, and other potential pitfalls, and identify them
  to the Coordinating Agent. Cite any files that you find that are relevant to
  the research task in your response.

  You are responding to another LLM; your response should be concise to save
  tokens, using abbreviations that another LLM will understand. Attempt to
  communicate the necessary information as tersely as possible to preserve the
  coordinating agent's context window.
  """
  # ----------------------------------------------------------------------------
  # AI.Agent Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt) do
      can_recurse? =
        inc_depth()
        |> case do
          {:ok, _} -> true
          {:error, :max_depth_reached} -> false
        end

      tools =
        if can_recurse? do
          AI.Tools.all_tools()
        else
          AI.Tools.all_tools()
          |> Map.drop(["research_tool"])
        end

      system_prompt =
        if can_recurse? do
          "#{@prompt}\n\n#{@research_tool_prompt}"
        else
          @prompt
        end

      try do
        AI.Completion.get(
          model: @model,
          toolbox: tools,
          messages: [
            AI.Util.system_msg(system_prompt),
            AI.Util.user_msg(prompt)
          ]
        )
        |> case do
          {:ok, %{response: response}} -> {:ok, response}
          {:error, %{response: response}} -> {:error, response}
        end
      after
        dec_depth()
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Agent
  # ----------------------------------------------------------------------------
  @max_researchers 10

  def start_link(), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def depth, do: Agent.get(__MODULE__, fn depth -> depth end)

  def inc_depth do
    Agent.get_and_update(__MODULE__, fn
      depth when depth >= @max_researchers ->
        {{:error, :max_depth_reached}, depth}

      depth ->
        {{:ok, depth + 1}, depth + 1}
    end)
  end

  def dec_depth do
    Agent.get_and_update(__MODULE__, fn
      0 ->
        {{:ok, 0}, 0}

      depth ->
        {{:ok, depth - 1}, depth - 1}
    end)
  end
end
