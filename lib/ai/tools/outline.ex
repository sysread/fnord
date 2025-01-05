defmodule AI.Tools.Outline do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "outline_tool",
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
              returned by the list_files_tool or the search_tool.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, project} <- get_project(),
         {:ok, entry} <- get_entry(project, file) do
      Store.Project.Entry.read_outline(entry)
    end
  end

  defp get_project() do
    project = Store.get_project()

    if Store.Project.exists_in_store?(project) do
      {:ok, project}
    else
      {:error, :project_not_found}
    end
  end

  defp get_entry(project, file) do
    entry = Store.Project.Entry.new_from_file_path(project, file)

    if Store.Project.Entry.exists_in_store?(entry) do
      {:ok, entry}
    else
      {:error, :entry_not_found}
    end
  end
end
