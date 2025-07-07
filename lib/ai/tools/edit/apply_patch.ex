defmodule AI.Tools.Edit.ApplyPatch do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "patch_id" => patch_id}) do
    with {:ok, path} <- Patches.get_patch(patch_id),
         {:ok, patch} <- File.read(path) do
      {"Applying patch ID #{patch_id} to #{file}",
       """
       # Patch File: #{path}
       ```
       #{patch}
       ```
       """}
    end
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "patch_id" => patch_id}, result) do
    {"Patch ID #{patch_id} applied to #{file}", result}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "apply_patch",
        description: """
        This tool applies a patch to a file. You must pass the exact, numerical
        ID provided to you when you created the patch. Do NOT pass the actual
        patch text to this tool; it will not work. Instead, you must use the
        make_patch tool to create the patch, which will return a patch ID.

        Patch IDs are valid for the duration of your response, meaning they can
        be used in any tool calls until you send your text response. If you
        create a patch and then ask the user for confirmation before applying
        it, you will need to recreate the patch in order to apply it.

        The original file will be modified in place, but a backup will be
        created with the extension `.bak` before applying the patch.
        """,
        parameters: %{
          type: "object",
          required: ["file", "patch_id"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to edit. It must be the complete path provided by the
              file_search_tool or file_list_tool.
              """
            },
            patch_id: %{
              type: "integer",
              description: """
              The ID of the patch to apply. The ID is provided by the
              make_patch tool when it generates the patch.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"file" => file, "patch_id" => patch_id}) do
    with patch_id <- Util.int_damnit(patch_id),
         {:ok, patch_file} <- Patches.get_patch(patch_id),
         {:ok, project} <- Store.get_project(),
         {:ok, path} <- Store.Project.find_file(project, file),
         :ok <- File.cp(path, backup_filename(path)),
         {output, 0} <- System.cmd("patch", [file, "-i", patch_file]) do
      {:ok,
       """
       The patch was successfully applied to `#{file}`.
       A backup of the original file has been created at `#{file}.bak`.
       Here is the output from the patch command:
       ```
       #{output}
       ```
       """}
    else
      {:error, :patch_not_found} ->
        {:error,
         """
         Patch ID #{patch_id} not found.
         Please ensure you have created the patch with the make_patch tool.
         Note that patch IDs are only valid for the duration of your response (e.g. all tool calls until you send your text response).
         If you created this patch in a previous round of tool calls, you will need to recreate it before applying it.
         """}

      {:error, reason} ->
        {:error, "Failed to apply patch: #{reason}"}
    end
  end

  defp backup_filename(path) do
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_string()
      # YYYYMMDDHHMMSS
      |> String.replace(~r/[^0-9]/, "")

    "#{path}.bak.#{timestamp}"
  end
end
