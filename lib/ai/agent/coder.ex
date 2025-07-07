defmodule AI.Agent.Coder do
  @behaviour AI.Agent

  @model AI.Model.smart()

  @max_attempts 3

  @identify_hunk_prompt """
  You are an AI agent tasked with finding code hunks in a file.
  The Coordinating Agent will provide you with a file name and instructions for changes it is implementing.
  Your task is to use the `find_code_hunks` tool to identify the specific hunk that corresponds with the changes requested.
  The `find_code_hunks` tools will return a list of possible hunks.
  You must select the single hunk that matches the intent of the Coordinating Agent's instructions.
  You may use the `file_contents_tool` to read the file in order to identify the correct hunk if necessary.
  Respond in JSON with the selected hunk. For example:
  ```json
  {
    "file": "path/to/file.ex",
    "start_line": 10,
    "end_line": 20
  }
  ```
  Do not include any other text (including markdown fences) in your response - **JUST** the JSON object.
  """

  @make_patch_prompt """
  You are an AI agent tasked with creating a patch for a code change.
  The Coordinating Agent will provide you with a file name, instructions for changes, and a hunk that has been identified.
  Your task is to use the `make_patch` tool to create a patch for the change.
  The `make_patch` tool will return a patch ID that can be used to apply the patch.
  Respond in JSON with the patch ID. For example:
  ```json
  {
    "patch_id": 123
  }
  ```
  Do not include any other text (including markdown fences) in your response - **JUST** the JSON object.
  """

  @impl AI.Agent
  def get_response(%{file: file, instructions: instructions}) do
    with {:ok, project} <- Store.get_project(),
         {:ok, path} <- Store.Project.find_file(project, file),
         {:ok, hunk} <- identify_hunk(path, instructions),
         {:ok, patch_id} <- make_patch(hunk, instructions),
         {:ok, result} <- apply_patch(path, patch_id) do
      {:ok, result}
    else
      {:patch_error, reason} ->
        {:error,
         """
         The patch was NOT applied successfully.

         The error was:
         #{reason}

         **`#{file}` was NOT modified.**
         """}
    end
  end

  defp identify_hunk(file, instructions, attempt \\ 1)

  defp identify_hunk(_, _, @max_attempts) do
    {:error, "Failed to identify hunk after #{@max_attempts} attempts"}
  end

  defp identify_hunk(file, instructions, attempt) do
    with {:ok, json} <- Jason.encode(%{file: file, instructions: instructions}) do
      AI.Completion.get(
        model: @model,
        log_msgs: true,
        log_tool_calls: true,
        toolbox:
          AI.Tools.build_toolbox([
            AI.Tools.File.Contents,
            AI.Tools.Edit.FindCodeHunks
          ]),
        messages: [
          AI.Util.system_msg(@identify_hunk_prompt),
          AI.Util.user_msg(json)
        ]
      )
      |> case do
        {:ok, %{response: response}} ->
          response
          |> Jason.decode()
          |> case do
            {:ok, %{"file" => _, "start_line" => _, "end_line" => _} = hunk} ->
              {:ok, hunk}

            {:ok, _} ->
              instructions = """
              #{instructions}
              -----
              Your previous response was not a valid hunk.
              Expected keys: "file", "start_line", "end_line".
              Response: #{response}
              """

              identify_hunk(file, instructions, attempt + 1)

            {:error, reason} ->
              instructions = """
              #{instructions}
              -----
              Your previous response was not valid JSON.
              Response: #{response}
              Error: #{reason}
              """

              identify_hunk(file, instructions, attempt + 1)
          end
      end
    end
  end

  defp make_patch(hunk, instructions, attempt \\ 1)

  defp make_patch(_, _, @max_attempts) do
    {:error, "Failed to create patch after #{@max_attempts} attempts"}
  end

  defp make_patch(hunk, instructions, attempt) do
    with {:ok, json} <- Jason.encode(%{hunk: hunk, instructions: instructions}) do
      AI.Completion.get(
        model: @model,
        log_msgs: true,
        log_tool_calls: true,
        toolbox: AI.Tools.build_toolbox([AI.Tools.Edit.MakePatch]),
        messages: [
          AI.Util.system_msg(@make_patch_prompt),
          AI.Util.user_msg(json)
        ]
      )
      |> case do
        {:ok, %{response: response}} ->
          response
          |> Jason.decode()
          |> case do
            {:ok, %{"patch_id" => patch_id}} ->
              {:ok, patch_id}

            {:ok, _} ->
              instructions = """
              #{instructions}
              -----
              Your previous response was was missing the "patch_id" field.
              Response: #{response}
              """

              make_patch(hunk, instructions, attempt + 1)

            {:error, reason} ->
              instructions = """
              #{instructions}
              -----
              Your previous response was not valid JSON.
              Response: #{response}
              Error: #{reason}
              """

              make_patch(hunk, instructions, attempt + 1)
          end
      end
    end
  end

  defp apply_patch(path, patch_id) do
    backup = backup_filename(path)

    with patch_id <- Util.int_damnit(patch_id),
         {:ok, patch_file} <- Patches.get_patch(patch_id),
         :ok <- File.cp(path, backup),
         {output, 0} <- System.cmd("patch", [path, "-i", patch_file]),
         {:ok, diff} <- Util.diff_files(backup, path) do
      {:ok,
       """
       The patch was successfully applied to `#{path}`.
       A backup of the original file has been created at `#{path}.bak`.

       Here is the output from the patch command:
       ```
       #{output}
       ```

       After patching, the file was compared to the backup, and the following changes were detected:
       ```
       #{diff}
       ```

       Please analyze the diff and the updated `#{path}` to ensure the changes are as expected.
       """}
    else
      {:error, :patch_not_found} ->
        if File.exists?(backup), do: File.rm(backup)

        {:patch_error,
         """
         Patch ID #{patch_id} not found.
         Please ensure you have created the patch with the make_patch tool.
         Note that patch IDs are only valid for the duration of your response (e.g. all tool calls until you send your text response).
         If you created this patch in a previous round of tool calls, you will need to recreate it before applying it.
         """}

      {:error, reason} ->
        if File.exists?(backup), do: File.rm(backup)

        {:patch_error, "Failed to apply patch: #{reason}"}
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
