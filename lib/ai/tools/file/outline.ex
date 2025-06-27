defmodule AI.Tools.File.Outline do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(%{"file" => file}), do: {:ok, %{"file" => file}}
  def read_args(%{"file_path" => file}), do: {:ok, %{"file" => file}}
  def read_args(_args), do: AI.Tools.required_arg_error("file")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_outline_tool",
        description: "Retrieves an outline of symbols and calls in an indexed code file.",
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The absolute file path to the code file in the project. This
              parameter MUST be a **confirmed file** in the repository, as
              returned by the file_list_tool or the file_search_tool.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, entry} <- AI.Tools.get_entry(file) do
      Store.Project.Entry.read_outline(entry)
    else
      :error ->
        {:error, "Missing required parameter: file."}

      {:error, :project_not_found} ->
        {:error, "This project has not yet been indexed by the user."}

      {:error, :enoent} ->
        {:error, "File path not found. Please verify the correct path."}
    end
  end
end
