defmodule AI.Tools.Strategies.List do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: "Listing research strategies"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "strategies_list_tool",
        description: """
        "Research Strategies" are research plans that can be used to guide the
        research strategy of the orchestrating AI agent. Research Strategies
        are agnostic to the project and the context of the user's query,
        instead focusing on the process to follow when researching specific
        classes of problems.

        It is up to **YOU** to decide which strategy is most appropriate for
        the user's query and to adapt it for the specific context.

        This tool lists all available research strategies by title.
        """,
        parameters: %{
          required: [],
          type: "object",
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(_completion, _args) do
    Store.Strategy.list()
    |> Enum.map(fn {title, _} -> "- #{title}" end)
    |> Enum.join("\n")
    |> then(&{:ok, &1})
  end
end
