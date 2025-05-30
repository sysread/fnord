defmodule AI.Tools.File.Info do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "question" => question}) do
    {"Considering [#{file}]", question}
  end

  def ui_note_on_request(args) do
    {"file_info_tool", "invalid arguments: #{inspect(args)}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "question" => question}, result) do
    {"Answered [#{file}]: #{question}", result}
  end

  def ui_note_on_result(_args, _result) do
    nil
  end

  @impl AI.Tools
  def read_args(args) do
    with {:ok, file} <- get_file(args),
         {:ok, question} <- get_question(args) do
      {:ok, %{"file" => file, "question" => question}}
    end
  end

  defp get_file(%{"file" => file}), do: {:ok, file}
  defp get_file(%{"file_path" => file}), do: {:ok, file}
  defp get_file(_args), do: AI.Tools.required_arg_error("file")

  defp get_question(%{"question" => question}), do: {:ok, question}
  defp get_question(_args), do: AI.Tools.required_arg_error("question")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_info_tool",
        description: """
        Requests information about a file. An LLM will use your question to
        extract relevant information from the file, preserving your own context
        window so you can focus on answering the user's questions. Specify
        exactly how you want the response formatted (e.g. exact code sections,
        interfaces, explanations, yes/no, etc.). The file path must match the
        one provided by the file_list_tool or file_search_tool to avoid enoent
        errors. This tool can use git to provide context about its history and
        differences from earlier version.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["file", "question"],
          properties: %{
            file: %{
              type: "string",
              description: "A file path from the file_list_tool or file_search_tool."
            },
            question: %{
              type: "string",
              description: "A complete prompt for the LLM to respond to."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_completion, args) do
    with {:ok, question} <- Map.fetch(args, "question"),
         {:ok, file} <- Map.fetch(args, "file"),
         {:ok, content} <- AI.Tools.get_file_contents(file),
         {:ok, response} <-
           AI.Agent.FileInfo.get_response(%{
             file: file,
             question: question,
             content: content
           }) do
      {:ok, "[file_info_tool]\n#{response}"}
    else
      {:error, :enoent} ->
        {:error,
         """
         The requested file (#{args["file"]}) does not exist.
         - If the file name is correct, verify the path using the search or the file listing tool.
         - It may have been added since the most recent reindexing of the project.
         - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.

         ARGS: #{inspect(args)}
         """}

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, :incorrect_argument_format}
    end
  end
end
