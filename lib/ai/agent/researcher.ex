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
  You are speaking to another LLM, not a human. Save tokens: use extremely terse, shorthand speech as long as meaning is clear.

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
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, prompt} <- Map.fetch(opts, :prompt) do
      UI.report_from(agent.name, prompt)

      can_recurse? =
        inc_depth()
        |> case do
          {:ok, _} -> true
          {:error, :max_depth_reached} -> false
        end

      tools =
        if can_recurse? do
          AI.Tools.basic_tools()
        else
          AI.Tools.basic_tools()
          |> Map.drop(["research_tool"])
        end
        |> AI.Tools.with_mcps()
        |> AI.Tools.with_frobs()
        |> AI.Tools.with_web_tools()

      system_prompt =
        if can_recurse? do
          "#{@prompt}\n\n#{@research_tool_prompt}"
        else
          @prompt
        end

      try do
        # Inherit the external-configs catalog from the parent session;
        # research sub-agents build fresh message lists that don't route
        # through Services.Conversation, so without this they never see
        # cursor rules / external skills that the coordinator sees.
        AI.Agent.get_completion(agent,
          model: @model,
          toolbox: tools,
          messages:
            [
              AI.Util.system_msg(AI.Util.project_context()),
              AI.Util.system_msg(system_prompt)
            ] ++
              ExternalConfigs.Catalog.system_messages() ++
              [AI.Util.user_msg(prompt)]
        )
        |> case do
          {:ok, %{response: response}} -> {:ok, response}
          {:error, %{response: response}} -> {:error, response}
          {:error, reason} -> {:error, reason}
        end
      after
        dec_depth()
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Depth tracking: controls recursion, where the researcher can call itself as
  # a tool call to investigate multiple lines of inquiry. Scoped per process
  # tree via Services.Globals so concurrent researchers don't interfere.
  # ----------------------------------------------------------------------------
  @max_researchers 10
  @globals_key :researcher_depth

  def depth, do: Services.Globals.get_env(:fnord, @globals_key, 0)

  def inc_depth do
    current = depth()

    if current >= @max_researchers do
      {:error, :max_depth_reached}
    else
      new_depth = current + 1
      Services.Globals.put_env(:fnord, @globals_key, new_depth)
      {:ok, new_depth}
    end
  end

  def dec_depth do
    current = depth()

    if current == 0 do
      {:ok, 0}
    else
      new_depth = current - 1
      Services.Globals.put_env(:fnord, @globals_key, new_depth)
      {:ok, new_depth}
    end
  end
end
