defmodule AI.Tools.Edit.FindCodeHunks do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "criteria" => criteria}) do
    {"Finding editable regions in #{file}", criteria}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "criteria" => criteria}, result) do
    {"Found editable regions in #{file}",
     """
     Criteria: #{criteria}
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(%{"file" => file, "criteria" => criteria}) do
    {:ok, %{"file" => file, "criteria" => criteria}}
  end

  def read_args(%{"file" => _}), do: AI.Tools.required_arg_error("criteria")
  def read_args(%{"criteria" => _}), do: AI.Tools.required_arg_error("file")

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "find_code_hunks",
        description: """
        In order to edit a file, you must first identify a contiguous section
        of code to make changes to. This tool uses an LLM to read through the
        file and return the line ranges of all contiguous sections of code that
        match your specific criteria. Once you have identified likely code
        hunks, you may select the one you intended to edit and use the
        make_patch tool to build a patch to apply your changes.
        """,
        parameters: %{
          type: "object",
          required: ["file", "criteria"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file in which to search for code hunks. It must be the complete
              path provided by the file_search_tool or file_list_tool.
              """
            },
            criteria: %{
              type: "string",
              description: """
              The criteria for identifying code hunks. Examples:
              - "The entire function named `calculate_total`"
              - "All lines that contain the word `TODO`"
              - "All imports in the file"
              - "The doc comment for the `User` struct"
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    with {:ok, file} <- Map.fetch(opts, "file"),
         {:ok, criteria} <- Map.fetch(opts, "criteria") do
      AI.Agent.HunkFinder.get_response(%{file: file, criteria: criteria})
    end
  end
end
