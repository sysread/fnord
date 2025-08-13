defmodule AI.Agent.Code.PatchMaker do
  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type hunk :: Hunk.t()

  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @format_error "The LLM responded with an invalid JSON format. Please try again."

  @pre_anchor "<!-- START OF SECTION TO REPLACE -->"
  @post_anchor "<!-- END OF SECTION TO REPLACE -->"

  @model AI.Model.reasoning(:medium)

  @prompt """
  # SYNOPSIS
  You are an AI agent within the fnord application.
  Your role is to adjust the proposed replacement text so it fits exactly into a given hunk of a file without breaking surrounding structure.
  Operate language and content agnostically by matching observable patterns in the file, not by parsing a specific language.

  #{AI.Agent.Code.Common.coder_values_prompt()}

  # PROCEDURE
  - Align indentation to the local baseline immediately before the hunk.
  - Preserve or synthesize contiguous leading and trailing markers at the hunk boundaries when obvious (comments, attributes, annotations, headings, fences).
  - Match local whitespace conventions, line endings, and ensure a final newline if the file uses one.
  - Conform to visible style cues where clear and consistent (quoting style, delimiter usage, trailing commas or list markers, fence styles).
  - Keep edits strictly within the hunk. Do not touch or require changes outside the selected range.
  - Maintain the intent of the replacement; do not add speculative code or prose.
  - The replacement will replace ALL lines of code within the hunk, starting from the first column of the first line and ending at the final column of the last line.
    You must ensure that the replacement lines fit neatly into the existing code structure without introducing syntax errors or misalignments.

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
         {:ok, hunk} <- Map.fetch(opts, :hunk),
         {:ok, replacement} <- Map.fetch(opts, :replacement),
         {:ok, name} <- Services.NamePool.checkout_name(),
         _ <- log_start(name, replacement),
         {:ok, prompt} <- build_prompt(file, hunk, replacement),
         {:ok, response} <- get_completion(prompt) do
      response
      |> Jason.decode(keys: :atoms!)
      |> case do
        {:ok, %{error: reason}} when byte_size(reason) > 0 ->
          {:error, reason}

        {:ok, %{replacement: replacement}} ->
          log_success(name, replacement)
          {:ok, trim_final_newline(replacement)}

        {:error, _} ->
          {:error, @format_error}
      end
    else
      :error ->
        {:error, "Missing required options"}

      {:error, reason} ->
        UI.error("Failed to conform replacement text", inspect(reason, pretty: true))
        {:error, reason}
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

  @spec build_prompt(binary, hunk, binary) :: {:ok, binary} | {:error, term}
  defp build_prompt(file, hunk, replacement) do
    with {:ok, context} <- Hunk.change_context(hunk, 5, @pre_anchor, @post_anchor) do
      prompt = """
      # FILE
      `#{file}`

      # REGION TO BE MODIFIED

      There are markers delimiting the section to be replaced so you know exactly where your code will fit.
      **Do NOT include the anchors in your replacement!**

      ```
      #{context}
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

  # Trim the final newline from the replacement text if present.
  # `Hunk.replace_in_file/2` adds a newline at the end when joining it with the
  # text that follows it in the file. That said, we only take ONE newline off
  # the end, so that the LLM can add additional whitespace when required.
  @spec trim_final_newline(binary) :: binary
  defp trim_final_newline(text) do
    if String.ends_with?(text, "\n") do
      String.replace_suffix(text, "\n", "")
    else
      text
    end
  end

  defp log_start(name, _replacement) do
    UI.info("#{name} is conforming the replacement to the target site")
  end

  defp log_success(name, _replacement) do
    UI.info("#{name} is SUCH a conformist")
  end
end
