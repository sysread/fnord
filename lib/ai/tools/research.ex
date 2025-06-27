defmodule AI.Tools.Research do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(args) do
    {"Researching", args["prompt"]}
  end

  @impl AI.Tools
  def ui_note_on_result(args, result) do
    {"Research complete",
     """
     # Prompt
     #{args["prompt"]}

     # Findings
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "research_tool",
        description: """
        **This is your research assistant.**

        Spin off a focused sub-research process to perform multiple lines of
        research in parallel, allowing you to gather information from multiple
        sources and synthesize findings into a hollistic view of the code base.

        Research is performed by another AI agent which has access to most of
        the same tools that you do to perform their task.

        !!! This is your most powerful tool !!!
        """,
        parameters: %{
          type: "object",
          required: ["prompt"],
          properties: %{
            prompt: %{
              type: "string",
              description: """
              The research task to perform. This should be a specific question
              or task that you want the AI agent to research. Provide context
              as needed to clarify the task, as they will be starting from
              scratch with no context. The more explicit and clear you are, the
              more likely they are to produce useful results.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    case Map.fetch(args, "prompt") do
      {:ok, prompt} -> AI.Agent.Researcher.get_response(%{prompt: prompt})
      :error -> {:error, "Missing required argument: prompt"}
    end
  end
end
