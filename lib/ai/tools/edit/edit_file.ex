defmodule AI.Tools.Edit.EditFile do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "instructions" => instructions}) do
    {"Requesting changes to #{file}", instructions}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "instructions" => instructions}, result) do
    {"Changes made to #{file}",
     """
     Instructions:
     > #{instructions}

     Result:
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "make_changes",
        description: """
        This tool uses an AI agent to make changes to a file based on
        specific instructions.

        It is designed to edit code files by replacing contiguous sections of
        the file (hunks) with new code blocks, one by one.

        Because the AI has a limited context window, it is recommended that
        you limit the number of changes per tool call.

        NEVER request multiple tool calls to the same file in parallel, as that
        will lead to a race condition where the tool call system will execute
        the changes in parallel, leading to a race condition that can lose
        changes.
        """,
        parameters: %{
          type: "object",
          required: ["file", "instructions"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to edit. It must be the complete path provided by the
              file_search_tool or file_list_tool.
              """
            },
            instructions: %{
              type: "string",
              description: """
              The instructions for the changes to be made. Instructions must be
              specific and detailed, outlining the exact changes desired, with
              clear identification of the code sections to be modified.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"file" => file, "instructions" => instructions}) do
    AI.Agent.Coder.get_response(%{file: file, instructions: instructions})
  end
end
