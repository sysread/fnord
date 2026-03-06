defmodule AI.Agent.Code.RePatcher do
  @moduledoc """
  This module's purpose is to highlight the frustrations of working with LLMs.
  """

  # ----------------------------------------------------------------------------
  # Constants
  # ----------------------------------------------------------------------------
  @model AI.Model.coding()

  @prompt """
  You are the "RePatcher" agent.
  The current crop of LLMs (yourself included) appear to be extremely overfitted to a tool called "apply_patch" for making code changes.

  You will be provided with an LLM-generated "patch" command or tool_call:
  - The patch might be some attempt at a unified diff, git-style diff, or some combination.
  - Sometimes the LLM tried to use the `shell_tool` to execute a non-existent `apply_patch` command on the host system.
  - Sometimes it tries to use `echo` or `cat` to write out the patch to a file and then apply it.
  - One of their favorites is `bash apply_patch << 'EOF' ... EOF`.

  It thinks it's cleverly adapting and being helpful, but it's not.
  Your job is to figure out what the LLM was trying to do, and then use the **correct tool**, `file_edit_tool`, to make the desired changes.
  This makes you the unsung hero of this system!

  # Process
  1. Parse the "patch" to identify the target file(s) and intended changes.
  2. Read each target file using `file_contents_tool`. The output will contain
     hashline identifiers: each line is prefixed with `<line>:<hash>|` where
     `<hash>` is a 4-character content fingerprint (e.g. `42:a3f1|  def foo`).
  3. For each change, use `file_edit_tool` with **hash-anchored replacement**:
     - `hashes`: collect the full `line:hash` identifier from each line in the
       contiguous region you want to replace (e.g. `"42:a3f1"` from `42:a3f1|text`).
       Every line in the region must be included, even unchanged lines.
     - `old_string`: copy the text of those lines WITHOUT hashline prefixes. This
       is a comprehension check proving you read the target correctly.
     - `new_string`: the replacement text with the patch's changes applied.
       Whitespace fitting is applied automatically, so focus on content correctness.
  4. Do NOT include hashline prefixes (e.g. `42:a3f1|`) in `old_string` or `new_string`.

  # Best practices
  - Prefer atomic, single-purpose `file_edit_tool` calls for each discrete edit.
  - Split multi-file or multi-step changes into separate, sequential tool calls.
  - Include exactly the lines that need to change plus minimal surrounding context
    to avoid hash collisions. For single-line changes, include 1-2 neighboring lines.
  - For deletion, set `new_string` to an empty string.
  - Avoid embedded shell gymnastics (e.g., here-doc patches); rely on `file_edit_tool` for clarity.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "re_patch_result",
      description: """
      """,
      schema: %{
        type: "object",
        required: ["success", "message"],
        additionalProperties: false,
        properties: %{
          success: %{
            type: "boolean",
            description: """
            Set to `true` if the patch was successfully converted and applied,
            and the `file_edit_tool` did not return an error.
            """
          },
          message: %{
            type: "string",
            description: """
            A human-readable message describing the result of the operation.

            If `success` is `true`, this should be a brief confirmation that
            the changes were applied successfully.

            If `success` is `false`, this should contain a descriptive error
            message with a clear explanation of why the change could not be
            applied, and suggestions for what additional information is needed
            to successfully apply the changes.
            """
          }
        }
      }
    }
  }

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, patch} <- Map.fetch(opts, :patch) do
      UI.report_from(agent.name, "Re-routing overfitted `apply_patch` attempt", patch)
      re_patch(agent, patch)
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp re_patch(agent, patch) do
    agent
    |> AI.Agent.get_completion(
      model: @model,
      log_msgs: false,
      log_tool_calls: true,
      response_format: @response_format,
      toolbox: %{
        "file_contents_tool" => AI.Tools.File.Contents,
        "file_edit_tool" => AI.Tools.File.Edit
      },
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        Here is the "patch" that the LLM attempted to apply using the non-existent "apply_patch" tool.
        Parse it to identify the target file(s) and intended changes.
        Read each file with `file_contents_tool` to get the current contents with hashline identifiers.
        Then use `file_edit_tool` with hash-anchored replacement: pass `line:hash` identifiers (e.g. `"42:a3f1"`) as hashes, plus old_string and new_string.

        ```
        #{patch}
        ```
        """)
      ]
    )
    |> case do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{response: response}} ->
        response
        |> SafeJson.decode()
        |> case do
          {:ok, %{"success" => true, "message" => message}} ->
            {:ok, message}

          {:ok, %{"success" => false, "message" => message}} ->
            {:error, message}

          _ ->
            {:error,
             """
             The patch could not be applied.
             Try using the `file_edit_tool` instead.
             """}
        end
    end
  end
end
