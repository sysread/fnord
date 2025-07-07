defmodule AI.Tools.Edit.MakePatch do
  # ----------------------------------------------------------------------------
  # AI.Tools implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{
        "file" => file,
        "start_line" => start_line,
        "end_line" => end_line,
        "new_code" => new_code
      }) do
    {"Building patch for #{file}:#{start_line}-#{end_line}",
     """
     ```
     #{new_code}
     ```
     """}
  end

  @impl AI.Tools
  def ui_note_on_result(
        %{
          "file" => file,
          "start_line" => start_line,
          "end_line" => end_line
        },
        result
      ) do
    {"Patch for #{file}:#{start_line}-#{end_line}", result}
  end

  @impl AI.Tools
  def read_args(args) do
    with {:ok, _} <- AI.Tools.get_arg(args, "file"),
         {:ok, _} <- AI.Tools.get_arg(args, "new_code"),
         {:ok, start_line} <- AI.Tools.get_arg(args, "start_line"),
         {:ok, end_line} <- AI.Tools.get_arg(args, "end_line"),
         {:start_line, {:ok, _}} <- {:start_line, Util.parse_int(start_line)},
         {:end_line, {:ok, _}} <- {:end_line, Util.parse_int(end_line)} do
      {:ok, args}
    else
      {:start_line, {:error, :invalid_integer}} ->
        {:error, :invalid_argument, "start_line must be an integer"}

      {:end_line, {:error, :invalid_integer}} ->
        {:error, :invalid_argument, "end_line must be an integer"}
    end
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "make_patch",
        description: """
        This tool builds a patch file that can be used to apply changes to a
        file. It accepts a "hunk" (a contiguous section of code defined by a
        file path, start line, and end line) and a block of code to replace the
        *entire hunk in full*.

        You will be provided with a patch ID that is used to apply the patch
        using the apply_patch tool.
        """,
        parameters: %{
          type: "object",
          required: ["file", "start_line", "end_line", "new_code"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to edit. It must be the complete path provided by the
              file_search_tool or file_list_tool.
              """
            },
            start_line: %{
              type: "integer",
              description: """
              The starting line number of the code hunk to edit. This is inclusive,
              meaning the line at this number will be included in the edit.
              """
            },
            end_line: %{
              type: "integer",
              description: """
              The ending line number of the code hunk to edit. This is inclusive,
              meaning the line at this number will be included in the edit.
              """
            },
            new_code: %{
              type: "string",
              description: """
              The complete replacement code that will replace the entire hunk
              specified by the start and end line numbers. This should include
              all lines of code you want to write, replacing the existing lines
              in the specified range. Pay special attention to indentation and
              syntax, as the new code will completely replace the old code,
              exactly as provided.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{
        "file" => file,
        "start_line" => start_line,
        "end_line" => end_line,
        "new_code" => new_code
      }) do
    with {:ok, contents} <- AI.Tools.get_file_contents(file),
         start_line <- Util.int_damnit(start_line),
         end_line <- Util.int_damnit(end_line),
         {:ok, new_contents} <- update_code(contents, start_line, end_line, new_code),
         {:ok, orig} <- make_temp_file(contents),
         {:ok, dest} <- make_temp_file(new_contents),
         {:ok, patch} <- make_patch(orig, dest),
         {patch_id, path} <- Patches.new_patch(patch) do
      UI.debug("New patch created with ID #{patch_id} at #{path}")

      {:ok,
       %{
         file: file,
         start_line: start_line,
         end_line: end_line,
         patch_id: patch_id,
         patch: """
         Here is the content of the patch you requested.
         You can apply this patch using the `apply_patch` tool with the patch_id, `#{patch_id}`.
         ```diff
         #{patch}
         ```
         """
       }}
    end
  end

  defp make_patch(orig, temp) do
    System.cmd("diff", ["-u", orig, temp])
    |> case do
      {_output, 0} -> {:error, "The patch contained no changes!"}
      {output, 1} -> {:ok, output}
      {output, _} -> {:error, "Error building patch:\n\n#{output}"}
    end
  end

  defp make_temp_file(contents) do
    with {:ok, path} <- Briefly.create(),
         :ok <- File.write(path, contents) do
      {:ok, path}
    end
  end

  defp update_code(contents, start_line, end_line, new_code) do
    lines = String.split(contents, "\n")
    pre = Enum.take(lines, start_line - 1)
    post = Enum.drop(lines, end_line)
    new_code_lines = String.split(new_code, "\n")
    new_contents = Enum.join(pre ++ new_code_lines ++ post, "\n")
    {:ok, new_contents}
  end
end
