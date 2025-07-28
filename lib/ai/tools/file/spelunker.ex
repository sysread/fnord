defmodule AI.Tools.File.Spelunker do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(%{
        "name" => name,
        "start_file" => start_file,
        "symbol" => symbol,
        "goal" => goal
      }) do
    {"#{name} is spelunking the code",
     """

     Start file: #{start_file}
         Symbol: #{symbol}
           Goal: #{goal}
     """}
  end

  @impl AI.Tools
  def ui_note_on_result(
        %{
          "name" => name,
          "start_file" => start_file,
          "symbol" => symbol,
          "goal" => goal
        },
        result
      ) do
    {"#{name} finished spelunking",
     """

     Start file: #{start_file}
         Symbol: #{symbol}
           Goal: #{goal}
     -----
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args) do
    with {:ok, symbol} <- read_symbol(args),
         {:ok, start_file} <- read_start_file(args),
         {:ok, goal} <- read_goal(args) do
      name =
        case Map.get(args, "name") do
          nil ->
            case AI.Agent.Nomenclater.get_response(args) do
              {:ok, generated_name} -> generated_name
              _ -> "file_spelunker"
            end

          provided_name ->
            provided_name
        end

      {:ok,
       %{
         "symbol" => symbol,
         "start_file" => start_file,
         "goal" => goal,
         "name" => name
       }}
    end
  end

  defp read_goal(%{"goal" => goal}), do: {:ok, goal}
  defp read_goal(_args), do: AI.Tools.required_arg_error("goal")

  defp read_symbol(%{"symbol" => symbol}), do: {:ok, symbol}
  defp read_symbol(_args), do: AI.Tools.required_arg_error("symbol")

  defp read_start_file(%{"start_file" => start_file}), do: {:ok, start_file}
  defp read_start_file(%{"start_file_path" => start_file}), do: {:ok, start_file}
  defp read_start_file(%{"file_path" => start_file}), do: {:ok, start_file}
  defp read_start_file(%{"file" => start_file}), do: {:ok, start_file}
  defp read_start_file(_args), do: AI.Tools.required_arg_error("start_file")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_spelunker_tool",
        description: """
        Instructs an LLM to trace execution paths through the code to identify
        callers, callees, paths, and conditional logic affecting them. It can
        answer goals about the structure of the code and traverse multiple
        files to provide a call tree.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["symbol", "start_file", "goal"],
          properties: %{
            symbol: %{
              type: "string",
              description: """
              A symbol to use as an anchor reference to start the search from.
              For example, a function name, variable, or value.
              """
            },
            start_file: %{
              type: "string",
              description: "A file path from the file_list_tool or file_search_tool."
            },
            goal: %{
              type: "string",
              description: """
              A prompt for the spelunker agent to respond to. For example:
              - Identify all functions called by <symbol>
              - Identify all functions that call <symbol>
              - Starting from <start file>:<symbol>, trace logic to <end file>:<symbol>
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, symbol} <- Map.fetch(args, "symbol"),
         {:ok, start_file} <- Map.fetch(args, "start_file"),
         {:ok, goal} <- Map.fetch(args, "goal") do
      AI.Agent.Spelunker.get_response(%{
        symbol: symbol,
        start_file: start_file,
        goal: goal
      })
    end
  end
end
