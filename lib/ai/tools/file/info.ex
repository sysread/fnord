defmodule AI.Tools.File.Info do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"files" => files, "question" => question}) do
    {"Considering #{Enum.join(files, ", ")}", question}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"files" => files, "question" => question}, result) do
    {"Finished considerable considerations",
     """
     # Files
     #{Enum.join(files, ", ")}

     # Question
     #{question}

     # Result(s)
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
        name: "file_info_tool",
        description: """
        Requests information about a file or files. An LLM will use your
        question to extract relevant information from each of the specified
        file, preserving your own context window so you can focus on answering
        the user's questions. Specify exactly how you want the response
        formatted (e.g. exact code sections, interfaces, explanations, yes/no,
        etc.). File paths must match the ones provided by the file_list_tool or
        file_search_tool to avoid enoent errors. This tool can use git to
        provide context about its history and differences from earlier version.
        """,
        parameters: %{
          type: "object",
          required: ["question", "files"],
          properties: %{
            question: %{
              type: "string",
              description: "A complete prompt for the LLM to respond to."
            },
            files: %{
              type: "array",
              items: %{type: "string"},
              description: """
              A list of file paths that the LLM should process. Each file will
              be delegated to the LLM in parallel, allowing you to perform the
              same inquiry over many files at once.

              This is extremely useful when the user has asked you to identify
              complex patterns across multiple files, such as "find all
              functions that call this function" or "find all methods that
              return a value of this type".
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, question} <- Map.fetch(args, "question"),
         {:ok, files} <- Map.fetch(args, "files") do
      files
      |> Util.async_stream(&process_file(&1, question))
      |> Stream.map(&format_response/1)
      |> Enum.join("\n\n-----\n\n")
      |> then(&{:ok, &1})
    end
  end

  @spec process_file(String.t(), String.t()) :: {String.t(), String.t()}
  defp process_file(file, question) do
    response =
      with {:ok, content} <- AI.Tools.get_file_contents(file),
           numbered = Util.numbered_lines(content),
           {:ok, response} <- get_agent_response(file, question, numbered) do
        # Add backup note if applicable
        case Services.BackupFile.describe_backup(file) do
          nil -> response
          desc -> "#{desc}\n\n#{response}"
        end
      else
        {:error, reason} ->
          """
          Unable to read the file contents for the requested file.
          - If the file name is correct (per the list_files_tool), verify the path using the search or the file listing tool.
          - It may have been added since the most recent reindexing of the project.
          - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.

          FILE:  #{file}
          ERROR: #{inspect(reason)}
          """
      end

    {file, response}
  end

  @spec get_agent_response(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, any()}
  defp get_agent_response(file, question, content) do
    AI.Agent.FileInfo.get_response(%{
      file: file,
      question: question,
      content: content
    })
  end

  @spec format_response({atom, {String.t(), String.t() | atom}}) :: String.t()
  defp format_response({:ok, {file, result}}) do
    """
    Line numbers are included (separated by `|`) for citation in your response.

    ## File
    #{file}

    ## Result
    #{result}
    """
  end

  defp format_response({:error, {file, reason}}) do
    """
    ## File
    #{file}

    ## Error
    An error occurred while processing the file:
    #{inspect(reason, pretty: true)}
    """
  end
end
