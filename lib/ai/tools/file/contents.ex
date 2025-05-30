defmodule AI.Tools.File.Contents do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Retrieving file", args["file"]}

  @impl AI.Tools
  def ui_note_on_result(args, _result), do: {"Retrieved file", args["file"]}

  @impl AI.Tools
  def read_args(%{"file" => file}), do: {:ok, %{"file" => file}}
  def read_args(%{"file_path" => file}), do: {:ok, %{"file" => file}}
  def read_args(_args), do: AI.Tools.required_arg_error("file")

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
            }
          }
        }
      }
    }
  end

  # TODO truncate file contents if above some threshold
  @impl AI.Tools
  def call(args) do
    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, content} <- AI.Tools.get_file_contents(file) do
      {:ok,
       """
       [file_contents_tool] Contents of #{file}:
       ```
       #{content}
       ```
       """}
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

      error ->
        error
    end
  end
end
