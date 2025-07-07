defmodule AI.Tools.Edit.RestoreBackup do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file}) do
    {"Restoring most recent backup for", file}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file}, _result) do
    {"Restored most recent backup for", file}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "restore_backup",
        description: """
        This tool restores the most recent backup of a file created by applying
        a patch. It replaces the original file with the contents of the backup
        file and removes the backup file after the restore is complete.
        """,
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to restore. It must be the complete path provided by the
              file_search_tool or file_list_tool. Only the most recent backup
              will be restored, and the original file will be replaced with the
              contents of the backup file. The backup file will be removed
              after the restore is complete.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"file" => file}) do
    with_lock(file, fn ->
      with {:ok, backup} <- most_recent_backup(file),
           {:ok, diff} <- Util.diff_files(file, backup),
           :ok <- File.rm(file),
           :ok <- File.rename(backup, file) do
        {:ok,
         """
         The most recent backup of `#{file}` has been restored successfully.
         The diff between the original file and the backup was:
         ```diff
         #{diff}
         ```
         """}
      end
    end)
  end

  defp with_lock(file, cb) do
    Mutex.with_lock(:fnord_mutex, file, cb)
  end

  defp most_recent_backup(file) do
    "#{file}.bak.*"
    |> Path.wildcard()
    |> Enum.sort(fn a, b ->
      timestamp_a = String.replace_leading(a, "#{file}.bak.", "")
      timestamp_b = String.replace_leading(b, "#{file}.bak.", "")
      timestamp_a >= timestamp_b
    end)
    |> case do
      [most_recent | _] -> {:ok, most_recent}
      [] -> {:error, :no_backup_found}
    end
  end
end
