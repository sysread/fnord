defmodule AI.Agent.HunkFinder do
  @model AI.Model.balanced()
  @max_attempts 3

  @prompt """
  You are an AI agent within the fnord application.
  Your role is to identify and extract contiguous sections of code (hunks) that match specific criteria from a file.
  You will be presented with the contents of a file.
  Each line in the file is preceeded by its 1-based line number and a pipe character (|).

  You will respond with a JSON object containing structured hunks:
  ```
  {
    "hunks": [
      {"start_line": <start_line_number>, "end_line": <end_line_number>},
      ...
    ]
  }
  ```

  You must take *great care* to ensure that:
  1. Each hunk is a contiguous section of code, meaning it must not skip ANY lines within the range.
  2. The `start_line` and `end_line` are inclusive, meaning the hunk includes both the first and last lines.
  3. The `start_line` is always less than or equal to the `end_line`.
  4. The `start_line` and `end_line` are ACCURATE and reflect the actual line numbers provided to you.
  5. Your search is exhaustive, meaning you should find ALL hunks that match the criteria.
     Err on the side of finding too many hunks rather than too few.
     You can never have too many hunks, amirite?

  Your response must be ONLY the JSON object, with no additional text, explanation, or formatting.
  Do not wrap it in code fences or any other formatting.
  """

  @type hunk :: %{
          start_line: non_neg_integer,
          end_line: non_neg_integer,
          contents: binary
        }

  @type response ::
          {:ok, list(hunk)}
          | {:error, binary}

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, file} <- Map.fetch(opts, :file),
         {:ok, criteria} <- Map.fetch(opts, :criteria),
         {:ok, contents} <- AI.Tools.get_file_contents(file) do
      get_completion(file, contents, criteria)
    end
  end

  @spec get_completion(binary, binary, binary, integer) :: response
  defp get_completion(file, contents, criteria, attempt \\ 0) do
    numbered_contents = Util.numbered_lines(contents)
    last_line_number = String.split(numbered_contents, "\n") |> length()

    msg = """
    # File: `#{file}`
    ```
    #{numbered_contents}
    ```

    # Criteria
    > #{criteria}
    """

    AI.Completion.get(
      model: @model,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(msg)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        with {:ok, data} <- Jason.decode(response),
             {:ok, hunks} <- Map.fetch(data, "hunks") do
          hunks
          |> Enum.reduce_while([], fn
            %{"start_line" => start_line, "end_line" => end_line}, acc ->
              if start_line <= end_line and end_line <= last_line_number do
                hunk = %{
                  start_line: start_line,
                  end_line: end_line,
                  contents:
                    numbered_contents
                    |> String.split("\n")
                    |> Enum.slice(start_line - 1, end_line - start_line + 1)
                    |> Enum.map(&String.replace(&1, ~r/^\d+\|/, ""))
                    |> Enum.join("\n")
                }

                {:cont, [hunk | acc]}
              else
                {:halt,
                 {:error,
                  "Invalid hunk: start_line #{start_line} is greater than end_line #{end_line}"}}
              end
          end)
          |> case do
            {:error, _} = err -> err
            hunks -> {:ok, Enum.reverse(hunks)}
          end
        else
          {:error, _} when attempt < @max_attempts ->
            UI.debug("HunkFinder: Retrying due to error in response parsing", """
            Response was:
            ```
            #{response}
            ```
            """)

            get_completion(file, contents, criteria, attempt + 1)

          {:error, _} ->
            {:error,
             """
             Failed to parse the JSON response from the AI agent:
             ```
             #{response}
             ```
             """}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
