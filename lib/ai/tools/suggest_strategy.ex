defmodule AI.Tools.SuggestStrategy do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"title" => title}) do
    {"Suggesting a new or refined research strategy", "#{title}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"title" => title}, _result) do
    {"Suggested a new or refined research strategy", "#{title}"}
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "suggest_strategy_tool",
        description: """
        "Research Strategies" are lists of actionable instructions for how to
        approach a class of research task. They may be granular descriptions of
        how to use a specific tool_call (e.g. "How to extract the body of a
        function" that explains how to use the `file_info_tool`) or broad
        strategies for how to approach a class of research task (e.g. "How to
        identify the root cause of a bug based on a stack trace", documenting a
        list of steps that could refer to other strategies like "How to extract
        the body of a function").
        """,
        parameters: %{
          type: "object",
          required: ["title", "plan"],
          properties: %{
            title: %{
              type: "string",
              description: """
              A very brief label for the research strategy describing what it
              is used to accomplish. Examples:
              - "Identify the root cause of a bug based on a stack trace"
              - "Create documentation for an undocumented module"
              - "Steps to refactor a legacy module"
              - "Identify the commit that introduced a bug"
              """
            },
            plan: %{
              type: "string",
              description: """
              A detailed plan for how to research this class of task. Each step
              should be clear, concise, and actionable. Steps may optionally
              identify specific tool calls that may assist with the research.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, title} <- Map.fetch(args, "title"),
         {:ok, plan} <- Map.fetch(args, "plan") do
      AI.Agent.Strategizer.get_response(agent.ai, %{
        title: title,
        plan: plan
      })
    end
  end
end
