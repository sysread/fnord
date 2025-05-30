defmodule AI.Agent.Researcher do
  @model AI.Model.fast()

  @prompt """
  You are an AI agent who performs research on behalf of the Coordinating Agent.
  They will provide you with a research task.
  You are to use your tools to gather information about the code base.
  Remember that many code bases are complex and contain legacy code, so you will need to make clever use of your tools to gather the information you need.
  Take special care to identify ambiguities in terminology, unexpected dependencies, oddities of code structure, and other potential pitfalls, and identify them to the Coordinating Agent.
  Include any files that you find that are relevant to the research task in your response.
  You are responding to another LLM; your response should be concise to save tokens, using abbreviations that another LLM will understand.
  """
  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with %{name: project} <- Store.get_project(),
         {:ok, prompt} <- Map.fetch(opts, :prompt) do
      AI.Completion.get(
        model: @model,
        tools: AI.Tools.all_tools_for_project(project),
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg(prompt)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, %{response: response}} -> {:error, response}
      end
    end
  end
end
