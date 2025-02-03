defmodule AI.Tools.Strategies.Get do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"title" => title}) do
    {"Retrieving research strategy", title}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(%{"title" => _} = args), do: {:ok, args}
  def read_args(_args), do: AI.Tools.required_arg_error("title")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "strategies_get_tool",
        description: """
        "Research Strategies" are research plans that can be used to guide the
        research strategy of the orchestrating AI agent. Research Strategies
        are agnostic to the project and the context of the user's query,
        instead focusing on the process to follow when researching specific
        classes of problems.

        It is up to **YOU** to decide which strategy is most appropriate for
        the user's query and to adapt it for the specific context.

        This tool retrieves a research strategy by its `title`.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["title"],
          properties: %{
            title: %{
              type: "string",
              description: """
              The title of the research strategy to retrieve.
              This must be an exact match.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_completion, args) do
    with {:ok, title} <- Map.fetch(args, "title"),
         {:ok, strategy} <- Store.Strategy.get(title) do
      {:ok, strategy}
    end
  end
end
