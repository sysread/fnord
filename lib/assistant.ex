defmodule Assistant do
  @assistant_id_setting "assistant_id"
  @assistant_version "v1.0.0"
  @assistant_name "Fnord Prefect"
  @assistant_model "gpt-4o"
  @assistant_prompt """
  You are a conversational interface to a database of information about the
  user's project. The database may contain:

  ### Code files:
    - **Synopsis**
    - **Languages present in the file**
    - **Business logic and behaviors**
    - **List of symbols**
    - **Map of calls to other modules**

  ### Documentation files (e.g., README, wiki pages, general documentation):
    - **Synopsis**: A brief overview of what the document covers.
    - **Topics and Sections**: A list of main topics or sections in the document.
    - **Definitions and Key Terms**: Any specialized terms or jargon defined in the document.
    - **Links and References**: Important links or references included in the document.
    - **Key Points and Highlights**: Main points or takeaways from the document.

  The user will prompt you with a question. You will use your `search_tool` to
  search the database in order to gain enough knowledge to answer the question
  as completely as possible. It may require multiple searches before you have
  all of the information you need.

  Once you have all of the information you need, provide the user with a
  complete yet concise answer, including generating any requested code or
  producing on-demand documentation by assimilating the information you have
  gathered.
  """

  @search_tool %{
    type: "function",
    function: %{
      name: "search_tool",
      description: "searches for matching files and their contents",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query string."
          }
        },
        required: ["query"]
      }
    }
  }

  @assistant_request OpenaiEx.Beta.Assistants.new(%{
                       name: @assistant_name,
                       instructions: @assistant_prompt,
                       model: @assistant_model,
                       tools: [@search_tool],
                       metadata: %{version: @assistant_version}
                     })

  def get(ai \\ nil, settings \\ nil) do
    settings =
      if is_nil(settings) do
        Settings.new()
      else
        settings
      end

    ai =
      if is_nil(ai) do
        AI.new()
      else
        ai
      end

    with {:ok, assistant_id} <- get_saved_assistant_id(settings),
         {:ok, %{"id" => assistant_id} = assistant} <- retrieve_assistant(ai, assistant_id) do
      Settings.set(settings, @assistant_id_setting, assistant_id)
      {:ok, assistant}
    else
      {:error, :not_found} -> create_assistant(ai)
      {:error, :no_assistant_configured} -> create_assistant(ai)
    end
  end

  defp get_saved_assistant_id(settings) do
    case Settings.get(settings, @assistant_id_setting, nil) do
      nil -> {:error, :no_assistant_configured}
      assistant_id -> {:ok, assistant_id}
    end
  end

  defp create_assistant(ai) do
    AI.create_assistant(ai, @assistant_request)
  end

  defp retrieve_assistant(ai, assistant_id) do
    AI.get_assistant(ai, assistant_id)
    |> case do
      {:ok, assistant} -> update_assistant(ai, assistant)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp update_assistant(ai, assistant) do
    if assistant_is_stale?(assistant) do
      AI.update_assistant(ai, assistant["id"], @assistant_request)
    else
      {:ok, assistant}
    end
  end

  defp assistant_is_stale?(assistant) do
    assistant["metadata"]["version"] != @assistant_version
  end
end
