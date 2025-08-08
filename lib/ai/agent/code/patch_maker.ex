defmodule AI.Agent.Code.PatchMaker do
  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @context_lines 10

  @format_error "The LLM responded with an invalid JSON format. Please try again."

  @model AI.Model.reasoning(:medium)

  @prompt """
  # SYNOPSIS
  You are an AI agent within the fnord application.
  Your role is to adjust the proposed replacement text so it fits exactly into a given hunk of a file without breaking surrounding structure.
  Operate language and content agnostically by matching observable patterns in the file, not by parsing a specific language.

  # PROCEDURE
  - Align indentation to the local baseline immediately before the hunk.
  - Preserve or synthesize contiguous leading and trailing markers at the hunk boundaries when obvious (comments, attributes, annotations, headings, fences).
  - Match local whitespace conventions, line endings, and ensure a final newline if the file uses one.
  - Conform to visible style cues where clear and consistent (quoting style, delimiter usage, trailing commas or list markers, fence styles).
  - Keep edits strictly within the hunk. Do not touch or require changes outside the selected range.
  - Maintain the intent of the replacement; do not add speculative code or prose.

  If a clean fit cannot be achieved without guessing, return an error that states what additional detail is needed.

  # OUTPUT
  Return a JSON object with:
  - `replacement`: the adjusted replacement text ready to splice into the hunk. If error, set to an empty string.
  - `error`: an empty string on success, otherwise a error response explaining why the replacement could not be made and how to improve the request.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "patch_maker_result",
      description: """
      A JSON object containing the corrected replacement text or an error
      message if the correction could not be made.
      """,
      schema: %{
        type: "object",
        required: ["replacement", "error"],
        additionalProperties: false,
        properties: %{
          replacement: %{
            type: "string",
            description: """
            The corrected replacement text that can be applied to the file.
            If `error` is set, this field MUST be an empty string.
            """
          },
          error: %{
            type: "string",
            description: """
            An error message if the correction could not be made.
            If `replacement` is set, this field MUST be an empty string.
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
    with {:ok, file} <- Map.fetch(opts, :file),
         {:ok, start_line} <- Map.fetch(opts, :start_line),
         {:ok, end_line} <- Map.fetch(opts, :end_line),
         {:ok, replacement} <- Map.fetch(opts, :replacement),
         {:ok, prompt} <- build_prompt(file, start_line, end_line, replacement),
         {:ok, response} <- get_completion(prompt) do
      response
      |> Jason.decode(keys: :atoms!)
      |> case do
        {:ok, %{error: reason}} when byte_size(reason) > 0 -> {:error, reason}
        {:ok, %{replacement: replacement}} -> {:ok, trim_final_newline(replacement)}
        {:error, _} -> {:error, @format_error}
      end
    else
      :error -> {:error, "Missing required options"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec get_completion(binary) :: {:ok, binary} | {:error, term}
  defp get_completion(prompt) do
    AI.Completion.get(
      model: @model,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(prompt)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, %{response: response}} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_prompt(binary, integer, integer, binary) :: {:ok, binary} | {:error, term}
  defp build_prompt(file, start_line, end_line, replacement) do
    with {:ok, content} <- File.read(file) do
      lines = String.split(content, "\n")
      pre = get_pre_context(lines, start_line)
      post = get_post_context(lines, end_line)
      hunk = hunk_lines(lines, start_line, end_line)

      prompt = """
      # FILE
      `#{file}`

      # REGION TO BE MODIFIED
      ```
      #{pre}
      <!-- START OF SECTION TO REPLACE -->
      #{hunk}
      <!-- END OF SECTION TO REPLACE -->
      #{post}
      ```

      # REPLACEMENT TEXT
      ```
      #{replacement}
      ```

      Please correct the replacement text so that it can be applied to the file without syntax errors.
      Ensure that the replacement dovetails neatly and correctly into the existing code, preserving the expected indentation and syntax.
      """

      {:ok, prompt}
    end
  end

  @spec hunk_lines(list(binary), integer, integer) :: binary
  defp hunk_lines(lines, start_line, end_line) do
    lines
    |> Enum.slice(start_line - 1, end_line - start_line + 1)
    |> Enum.join("\n")
  end

  @spec get_pre_context(list(binary), integer) :: binary
  defp get_pre_context(lines, start_line) do
    start_index = max(0, start_line - @context_lines - 1)

    lines
    |> Enum.slice(start_index, start_line - start_index - 1)
    |> Enum.join("\n")
  end

  @spec get_post_context(list(binary), integer) :: binary
  defp get_post_context(lines, end_line) do
    end_index = min(length(lines), end_line + @context_lines)

    lines
    |> Enum.slice(end_line, end_index - end_line)
    |> Enum.join("\n")
  end

  @spec trim_final_newline(binary) :: binary
  defp trim_final_newline(text) do
    if String.ends_with?(text, "\n") do
      String.replace_suffix(text, "\n", "")
    else
      text
    end
  end
end
