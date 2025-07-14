defmodule AI.Tools.File.Contents do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "line_numbers" => true}) do
    {"Retrieving file +ln", file}
  end

  def ui_note_on_request(%{"file" => file}) do
    {"Retrieving file -ln", file}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_contents_tool",
        description: """
        Display the contents of a file in the project. Note that this retrieves
        the ENTIRE file. If the file is large, this may fail due to limits on
        the size of messages, or it may pull so much content into your context
        window that you forget the user's prompt or begin hallucinating
        responses. If you only need to learn specific facts or extract a
        section of code, use the file_info_tool to preserve your context
        window.
        """,
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file whose contents you wish to review. It must be the
              complete path provided by the file_search_tool or file_list_tool.
              """
            },
            line_numbers: %{
              type: "boolean",
              description: "If true (default), prefix each line with its 1-based line number.",
              default: true
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"file" => file} = args) do
    line_numbers = Map.get(args, "line_numbers", true)

    with {:ok, content} <- AI.Tools.get_file_contents(file) do
      output =
        content
        |> maybe_number_lines(line_numbers)
        |> wrap_content(file)

      {:ok, output}
    else
      {:error, :enoent} ->
        {:error,
         """
         The requested file (#{args["file"]}) does not exist.
         - If the file name is correct, verify the path using the search or the file listing tool.
         - It may have been added since the most recent reindexing of the project.
         - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.
         """}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wrap_content(text, file) do
    """
    [file_contents_tool] Contents of #{file}:
    ```
    #{text}
    ```
    """
  end

  defp maybe_number_lines(text, true), do: Util.numbered_lines(text, "\t")
  defp maybe_number_lines(text, _), do: text
end
