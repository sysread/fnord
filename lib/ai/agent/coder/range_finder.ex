defmodule AI.Agent.Coder.RangeFinder do
  @max_attempts 3

  @model AI.Model.balanced()

  @prompt """
  You are an AI coding assistant within a larger AI system.
  The Coordinating Agent asks you to identify a contiguous range of lines in a file based on the provided instructions for a coding task it is planning.
  Identify the *single*, contiguous range of lines in the file to be replaced, based on the instructions.
  Use your programming expertise to ensure that the range is appropriate to the intent of the instructions.
  For example, if asked to add a function at the end of the file, ensure the range would place the new function in a syntactically appropriate location.
  If the instructions are ambiguous or do not clearly point to a single range, respond with an error message that clearly explains the problem.

  Note: The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).

  # Response Format
  Constraints:
  - `start_line` <= `end_line`
  - `start_line` >= 1
  - `end_line` <= the number of lines in the file
  - if `start_line` == `end_line`, the range is a single line
  - The instructions will be applied to *fully* replace the identified range, so the range must cover the entire area to be replaced.

  You MUST respond ONLY with a single JSON object with the following fields, based on whether you were able to identify a range:
  **Success:** `{"start_line": <start_line>, "end_line": <end_line>}`
  **Failure:** `{"error": "<error message>"}`

  Do not include any other text, comments, explanations, or markdown fences in your response.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, file} <- Map.fetch(opts, :file) do
      identify_range(file, instructions)
    else
      :error -> {:error, "Incorrect arguments passed to AI.Agent.Coder.RangeFinder."}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec identify_range(binary, binary, integer) ::
          {:ok, {integer, integer}}
          | {:identify_error, binary}
          | {:error, binary}
          | {:error, :max_attempts_reached}
  defp identify_range(file, instructions, attempt \\ 1)

  defp identify_range(_, _, attempt) when attempt > @max_attempts do
    {:error, "Maximum attempts reached while trying to apply changes."}
  end

  defp identify_range(file, instructions, attempt) do
    file_contents =
      file
      |> File.read!()
      |> Util.numbered_lines()

    user = """
    Please identify the range of lines in the file that should be replaced based on the following instructions.

    # Instructions
    #{instructions}

    # File: #{file}
    ```
    #{file_contents}
    ```
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
          {:ok, %{"start_line" => start_line, "end_line" => end_line}} ->
            file_contents
            |> validate_range(start_line, end_line)
            |> case do
              :ok -> {:ok, {start_line, end_line}}
              {:error, _error} -> identify_range(file, instructions, attempt + 1)
            end

          {:ok, %{"error" => msg}} ->
            {:identify_error, msg}
        end

      {:error, _reason} ->
        identify_range(file, instructions, attempt + 1)
    end
  end

  @spec validate_range(binary, integer, integer) :: :ok | {:error, binary}
  defp validate_range(contents, start_line, end_line) do
    lines = num_lines(contents)

    cond do
      start_line < 1 ->
        {:error, "Start line must be greater than or equal to 1."}

      start_line > lines ->
        {:error, "Start line exceeds the number of lines in the file."}

      end_line < start_line ->
        {:error, "End line must be greater than or equal to start line."}

      lines > 0 && end_line > lines ->
        {:error, "End line exceeds the number of lines in the file."}

      true ->
        :ok
    end
  end

  @spec num_lines(binary) :: integer
  defp num_lines(str) do
    str
    |> String.split("\n", trim: false)
    |> length()
  end
end
