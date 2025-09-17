defmodule AI.Agent.Code.Patcher do
  # ----------------------------------------------------------------------------
  # Constants
  # ----------------------------------------------------------------------------
  @model AI.Model.reasoning(:low)

  @max_retries 2

  @prompt """
  # Synopsis
  You are the Patcher, an AI Agent that applies changes to a file.
  You are an expert programmer and can understand the syntax and semantics of the file's contents.
  You are clever enough to DWIM and interpret the intent of changes requested by the Coordinating Agent, adapting them to the file's context.
  You will be provided with the contents of a file and a series of changes to apply to the file.
  If you cannot a change, you must return an error.

  # Line Numbers
  Line numbers appear as a number, followed by a pipe (`|`) character, followed *immediately* by the line text (no additional whitespace).

  These numbered lines:
  ```
  1|This is the first line of the file.
  2|  - This is the second line of the file.
  ```

  Equate to this content:
  ```
  This is the first line of the file.
    - This is the second line of the file.
  ```

  # Process
  You will be provided with a file's contents and each change in turn.
  1. Identify the smallest contiguous range of lines required to apply the *complete* change.
     All lines identified will be replaced *in their entirety*.
  2. Generate a *complete* replacement for those lines.
  3. You MUST ensure that the indentation is correct and consistent, paying special attention to whitespace (e.g. tabs vs spaces).
  4. You MUST ensure that the syntax of the replacement is correct and that it can be applied to the file without syntax errors.
  5. Do NOT include the prefixed line numbers in the replacement text.

  # Validation
  After making a change, you MUST use the tools available to the project or
  language ecosystem to validate that the change is correct and does not
  introduce syntax errors or other issues.

  # Best practices
  - Generate linear, atomic patches; avoid complex nested conditionals in a single patch.
  - If a requested change implies multiple steps, propose sequential, small patches rather than nesting logic.
  - Use early validation or checks to enforce invariants before proceeding with deeper edits.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "patch",
      description: """
      A JSON object describing an individual patch to a contiguous range of
      lines within the file.

      If you are unable to identify a suitable range or replacement for the
      requested change, return an empty `patch` (setting line numbers to `-1`
      and the replacement to an empty string) and set the `error` field to a
      descriptive error message with a clear explanation of why the change
      could not be applied, and suggestions for what additional information is
      needed to successfully apply the changes.
      """,
      schema: %{
        type: "object",
        required: ["error", "start_line", "end_line", "replacement"],
        additionalProperties: false,
        properties: %{
          error: %{
            type: "string",
            description: """
            An error message if the patch could not be generated.
            If you were able to come up with a patch, this MUST be an empty string.
            """
          },
          start_line: %{
            type: "integer",
            description: """
            The 1-based line number where the patch starts (inclusive).
            If `error` is set, this MUST be `-1`.
            """
          },
          end_line: %{
            type: "integer",
            description: """
            The 1-based line number where the patch ends (inclusive).
            If `error` is set, this MUST be `-1`.
            """
          },
          replacement: %{
            type: "string",
            description: """
            The corrected replacement text that can be applied to the file.
            If the replacement is an empty string, the entire hunk will be deleted.
            If `error` is set, this MUST be an empty string.
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
    with {:ok, state} <- new(opts),
         {:ok, %{contents: contents}} <- apply_changes(state) do
      {:ok, contents}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defstruct [
    :agent,
    :file,
    :changes,
    :contents,
    :tools,
    :retry_counts
  ]

  @type t :: %__MODULE__{
          agent: AI.Agent.t(),
          file: binary,
          changes: list(binary),
          contents: binary,
          tools: map(),
          retry_counts: map()
        }

  @spec new(map) :: {:ok, t} | {:error, binary}
  defp new(opts) do
    with {:ok, agent} <- required_arg(opts, :agent),
         {:ok, file} <- required_arg(opts, :file),
         {:ok, changes} <- required_arg(opts, :changes),
         {:ok, contents} <- AI.Tools.get_file_contents(file) do
      UI.report_from(agent.name, "Patching #{file}")

      # Build the toolbox once per apply_changes session
      tools =
        %{"shell_tool" => AI.Tools.Shell}
        |> Map.merge(Frobs.module_map())

      {:ok,
       %__MODULE__{
         agent: agent,
         file: file,
         changes: changes,
         contents: contents,
         tools: tools,
         retry_counts: %{}
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason, pretty: true, limit: :infinity)}
    end
  end

  @spec apply_changes(t) :: {:ok, t} | {:error, binary}
  defp apply_changes(%{changes: []} = state), do: {:ok, state}

  defp apply_changes(%{changes: [change | remaining], contents: contents} = state) do
    UI.report_from(state.agent.name, "[#{state.file}] #{change}")

    numbered = Util.numbered_lines(contents)

    AI.Agent.get_completion(state.agent,
      model: @model,
      response_format: @response_format,
      log_msgs: false,
      log_tool_calls: true,
      toolbox: state.tools,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        File contents:
        ```
        #{numbered}
        ```

        Please apply the following change to the file contents above:
        #{change}
        """)
      ]
    )
    |> case do
      {:error, reason} ->
        attempts = Map.get(state.retry_counts, change, 0) + 1

        if attempts <= @max_retries do
          updated_state = %{state | retry_counts: Map.put(state.retry_counts, change, attempts)}
          apply_changes(updated_state)
        else
          {:error, "Failed to apply change after #{@max_retries} attempts: #{reason}"}
        end

      {:ok, %{response: response}} ->
        case parse_patch_response(response) do
          {:ok, {start_line, end_line, replacement}} ->
            %{state | changes: remaining}
            |> replace_contents(start_line, end_line, replacement)
            |> apply_changes()

          {:error, reason} ->
            error_response(change, reason)
        end
    end
  end

  @spec replace_contents(t, integer, integer, binary) :: t
  defp replace_contents(%{contents: ""} = state, 0, 0, replacement) do
    %{state | contents: replacement}
  end

  defp replace_contents(%{contents: contents} = state, start_line, end_line, replacement) do
    lines = String.split(contents, "\n")

    # Clamp counts to avoid negative indices
    before_count = max(start_line - 1, 0)
    after_count = max(end_line, 0)

    lines_before = Enum.take(lines, before_count)
    lines_after = Enum.drop(lines, after_count)
    lines_within = String.split(replacement, "\n")

    new_contents =
      [lines_before, lines_within, lines_after]
      |> List.flatten()
      |> Enum.join("\n")

    %{state | contents: new_contents}
  end

  @spec error_response(binary, any) :: {:error, binary}
  defp error_response(change, reason) do
    {:error,
     """
     The following change could not be applied:
     #{change}

     The AI Agent returned an error:
     #{inspect(reason, pretty: true, limit: :infinity)}
     """}
  end

  @doc false
  # Parses the LLM JSON response into patch tuple or error
  defp parse_patch_response(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        patch = Map.get(decoded, "patch", decoded)

        case Map.get(patch, "error", "") do
          "" ->
            start_line = Map.get(patch, "start_line")
            end_line = Map.get(patch, "end_line")
            replacement = Map.get(patch, "replacement")

            if is_integer(start_line) and is_integer(end_line) and start_line >= 1 and
                 start_line <= end_line and is_binary(replacement) do
              {:ok, {start_line, end_line, replacement}}
            else
              {:error, "Invalid patch structure"}
            end

          reason ->
            {:error, reason}
        end

      {:error, error} ->
        {:error, "JSON parse error: #{inspect(error)}"}
    end
  end

  @spec required_arg(map, atom) :: {:ok, any} | {:error, binary}
  defp required_arg(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "Missing required parameter: #{key}"}
    end
  end
end
