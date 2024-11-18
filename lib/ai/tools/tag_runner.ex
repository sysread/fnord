defmodule AI.Tools.TagRunner do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "tag_runner_tool",
        description: "",
        parameters: %{
          type: "object",
          required: ["symbol", "start_file", "question"],
          properties: %{
            symbol: %{
              type: "string",
              description: """
              The symbol to use as a reference when either tracing callees,
              calleers, or paths through the code base.
              """
            },
            start_file: %{
              type: "string",
              description: """
              Absolute file path to the code file in the project from which the
              search will start.
              """
            },
            question: %{
              type: "string",
              description: """
              Instructs the Tag Runner agent what to trace. For example:
              - Starting from <start file>, trace the path from <symbol> to <symbol in another file>.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, symbol} <- Map.fetch(args, "symbol"),
         {:ok, start_file} <- Map.fetch(args, "start_file"),
         {:ok, question} <- Map.fetch(args, "question") do
      status_id =
        Tui.add_step(
          "Navigating the code base",
          "[#{start_file}:#{symbol}] #{question}"
        )

      result =
        agent.ai
        |> AI.Agent.TagRunner.new(agent.opts, symbol, start_file, question)
        |> AI.Agent.TagRunner.trace()
        |> IO.inspect()

      Tui.finish_step(status_id, :ok)

      result
    end
  end
end
