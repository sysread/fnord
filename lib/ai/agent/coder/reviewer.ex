defmodule AI.Agent.Coder.Reviewer do
  @max_attempts 3

  @model AI.Model.reasoning(:high)

  @prompt """
  You are an AI coding assistant within a larger AI system.
  The Coordinating Agent has asked you to confirm the changes made to a file based on the provided preview.
  You are required to confirm whether the changes are 1) correct, 2) syntactically valid, 3) true to the intent of the instructions.
  Use your programming knowledge to determine if the changes are syntactically correct.
  Use your experience as an engineer to determine if the changes are true to the intent of the instructions.

  Additionally, look for common LLM code generation artifacts, such as:
  - Comments that break the fourth wall (e.g. `# Changed to use X, per instructions`)
  - Explanations and summaries that are not in-code comments or documentation
  - Line numbers

  If any significant issues are identified, respond with a clear error message explaining the problem.
  Bonus points if you can suggest improved instructions to avoid the issue on the next attempt.

  Note: The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).
  Note: The overall change has been split up into smaller hunks, each to a single, contiguous section of the file.
        Only review this change to *this* hunk, not the entire file, or the entire change set.

  # Response Format
  Respond ONLY with one of the two following JSON objects:
  **Success:** `{"valid": true}`
  **Failure:** `{"valid": false, "error": "<clear explanation of the problem>"}`

  Do not include any other text, comments, explanations, or markdown fences in your response.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, file} <- Map.fetch(opts, :file),
         {:ok, preview} <- Map.fetch(opts, :preview) do
      confirm_changes(file, instructions, preview)
    else
      :error -> {:error, "Incorrect arguments passed to AI.Agent.Coder.Reviewer."}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec confirm_changes(binary, binary, binary, integer) ::
          :ok
          | {:error, binary}
          | {:error, :max_attempts_reached}
          | {:confirm_error, binary}
  defp confirm_changes(file, instructions, preview, attempt \\ 1)

  defp confirm_changes(_, _, _, attempt) when attempt > @max_attempts do
    {:error, "Maximum attempts reached while trying to apply changes."}
  end

  defp confirm_changes(file, instructions, preview, attempt) do
    file_contents =
      file
      |> File.read!()
      |> Util.numbered_lines()

    user = """
    Please confirm the changes made to the file based on the file contents and preview of the change.

    # Instructions
    #{instructions}

    # File: #{file}
    ```
    #{file_contents}
    ```

    # Preview of Change
    #{preview}
    """

    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(user)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> Jason.decode()
        |> case do
          {:ok, %{"valid" => true}} -> :ok
          {:ok, %{"valid" => false, "error" => msg}} -> {:confirm_error, msg}
          {:ok, %{"error" => error}} -> {:confirm_error, error}
          {:error, _} -> confirm_changes(file, instructions, preview, attempt + 1)
        end

      {:error, _} ->
        confirm_changes(file, instructions, preview, attempt + 1)
    end
  end
end
