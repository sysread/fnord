defmodule AI.Tools.Strategies.Save do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"title" => title, "id" => id}) do
    {"Updating research strategy", "#{title} (id: #{id})"}
  end

  def ui_note_on_request(%{"title" => title}) do
    {"Saving new research strategy", "#{title}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"title" => title, "id" => id}, _result) do
    {"Updated research strategy", "#{title} (id: #{id})"}
  end

  def ui_note_on_result(%{"title" => title}, _result) do
    {"Saved new research strategy", "#{title}"}
  end

  @impl AI.Tools
  def read_args(args) do
    with {:ok, title} <- get_title(args),
         {:ok, prompt_text} <- get_prompt(args),
         {:ok, questions} <- get_questions(args) do
      id = Map.get(args, "id", nil)

      {:ok,
       %{
         "title" => title,
         "prompt" => prompt_text,
         "questions" => questions,
         "id" => id
       }}
    end
  end

  defp get_title(%{"title" => title}), do: {:ok, title}
  defp get_title(_args), do: AI.Tools.required_arg_error("title")

  defp get_prompt(%{"prompt" => prompt}), do: {:ok, prompt}
  defp get_prompt(_args), do: AI.Tools.required_arg_error("prompt")

  defp get_questions(%{"questions" => questions}), do: {:ok, questions}
  defp get_questions(_args), do: AI.Tools.required_arg_error("questions")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "strategies_save_tool",
        description: """
        "Research Strategies" are previously saved prompts that can be used to
        guide the research strategy of the orchestrating AI agent.

        This tool saves a new research strategy or updates an existing one. If
        you want to update an existing strategy, you must include the ID of the
        strategy exactly as it was provided by the strategies_search_tool. This
        parameter should be left out when saving a new strategy.

        Research strategies should ALWAYS be general enough to apply to all
        software projects, not just the currently selected one. They should be
        100% orthogonal to the project, language, or domain.
        """,
        parameters: %{
          type: "object",
          required: ["title", "prompt", "questions"],
          properties: %{
            id: %{
              type: "string",
              description: """
              Existing strategies identified by the strategies_search_tool may
              be updated by providing the ID of the strategy to update. The ID
              MUST be one provided by the strategies_search_tool, verbatim.
              """
            },
            title: %{
              type: "string",
              description: """
              A very brief label for the research strategy.
              This should be completely orthogonal to any specific project or the details of the user's current query.
              Examples:
              - "Identify the root cause of a bug based on a stack trace"
              - "Create documentation for an undocumented module"
              - "Steps to refactor a legacy module"
              - "Identify the commit that introduced a bug"
              """
            },
            prompt: %{
              type: "string",
              description: """
              The prompt text of the research strategy.
              Prompts should capture the classification of the research strategy, not the specifics of any particular project or the domain of the user's current query.
              Prompts should be written as an imperative, actionable list of concrete research steps.
              """
            },
            questions: %{
              type: "array",
              items: %{type: "string"},
              description: """
              Provide a list of example questions for which this research strategy is appropriate to solve.
              Questions should be semantically related to the title and prompt to ensure effective matching using cosine similarity.
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
         {:ok, prompt_text} <- Map.fetch(args, "prompt"),
         {:ok, questions} <- Map.fetch(args, "questions") do
      id = Map.get(args, "id", nil)
      prompt = Store.Prompt.new(id)

      if is_nil(id) || Store.Prompt.exists?(prompt) do
        Store.Prompt.write(prompt, title, prompt_text, questions)
        {:ok, "Research strategy saved successfully."}
      else
        {:error, "The provided ID does not exist."}
      end
    end
  end
end
