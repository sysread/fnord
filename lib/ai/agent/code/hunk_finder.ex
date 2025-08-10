defmodule AI.Agent.Code.HunkFinder do
  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type candidate_range :: %{
          start_line: non_neg_integer,
          end_line: non_neg_integer,
          error: binary
        }

  @type hunk :: Hunk.t()

  @type response :: {:ok, list(hunk)} | {:error, binary}

  # ----------------------------------------------------------------------------
  # Constants
  # ----------------------------------------------------------------------------
  @model AI.Model.reasoning(:low)

  @prompt """
  # SYNOPSIS
  You are a surgical text extractor.
  Your job is to select exactly the contiguous lines in a file that should be replaced by the provided replacement text.
  Think like an editor preparing a clean diff.

  # INPUT
  You receive:
  - **File contents:** the complete file with line numbers (1-based).
  - **Criteria:** may be vague instructions or a possibly skewed snippet; treat `...` as a wildcard spanning any text across any number of lines.
  - **Replacement text:** may differ in indentation, include or omit surrounding comments/attributes, and may begin or end at logical boundaries.

  # PRINCIPLES
  - **Criteria is a clue, not a contract:** find the most plausible contiguous block that matches the intent.
  - **Replacement is the anchor:** choose the smallest span that the replacement can cleanly slot into without breaking surrounding structure.
  - **Dovetail rule:** if the replacement's first non-empty line begins with leading markers (eg comments, annotations, attributes, headings), include the immediately contiguous lines above the target that carry the same leading marker.
    Blank lines break contiguity.
  - **No context padding:** do not include extra lines that would cause the replacement to overwrite unrelated text.
  - **Wildcards:** treat `...` in the criteria as a non-greedy wildcard that can match across lines.
  - **Ambiguity:** if two or more spans are equally good, respond with an `error` requesting more specific criteria.

  # PROCEDURE
  1) Inspect the criteria.
     If it contains text from the file, perform a fuzzy match using the wildcard rule to find candidate spans.
     If it is purely descriptive, identify the single best contiguous span based on intent.
  2) Compare each plausible span against the replacement for boundary fit:
     - Leading and trailing line shape (markers like @, #, //, <!--, ```, ---, or similar).
     - Logical start and end (function or section boundaries, fenced blocks, paragraphs, etc.), using obvious textual cues only.
  3) Choose the smallest span that:
     (a) aligns with the criteria's intent,
     (b) allows the replacement to dovetail cleanly,
     (c) does not orphan partial constructs at the edges.
  4) If you cannot select a single best span without guessing, return an error that requests specific extra information.
     For example: an arity, a nearby line, or the exact heading.
     ...Something that would help you to anchor the section to be replaced.

  # OUTPUT
  Return a JSON object with:
  - `start_line`: 1-based inclusive start. If error, set to -1.
  - `end_line`: 1-based inclusive end. If error, set to -1.
  - `error`: empty string on success, otherwise a concise message.

  Respond with the JSON object only.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "hunk_finder_result",
      description: """
      A JSON object describing the identified hunk or an error if the hunk
      could not be identified.
      """,
      schema: %{
        type: "object",
        required: ["start_line", "end_line", "error"],
        additionalProperties: false,
        properties: %{
          start_line: %{
            type: "integer",
            description: """
            The 1-based line number where the hunk starts (inclusive).
            If `error` is set, this field MUST be -1.
            """
          },
          end_line: %{
            type: "integer",
            description: """
            The 1-based line number where the hunk ends (inclusive).
            If `error` is set, this field MUST be -1.
            """
          },
          error: %{
            type: "string",
            description: """
            An error message explaining why the hunk could not be identified.
            Use an empty string if the hunk was successfully identified.
            If either `start_line` and `end_line` are set, this field MUST be an empty string.
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
         {:ok, criteria} <- Map.fetch(opts, :criteria),
         {:ok, replacement} <- Map.fetch(opts, :replacement),
         {:ok, contents} <- File.read(file),
         {:ok, name} <- AI.Agent.Nomenclater.get_response(%{}),
         _ <- log_start(name, file, criteria, replacement),
         {:ok, hunk} <- find_hunk(file, contents, criteria, replacement) do
      log_success(name, hunk)
      {:ok, hunk}
    else
      :error ->
        {:error, :missing_required_parameters}

      {:error, reason} ->
        UI.error("Failed to identify hunk", inspect(reason, pretty: true))
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec find_hunk(
          file :: binary,
          contents :: binary,
          criteria :: binary,
          replacement :: binary
        ) ::
          {:ok, hunk}
          | {:error, term}
  defp find_hunk(file, "", _criteria, _replacement) do
    Hunk.new(file, 0, 0)
  end

  defp find_hunk(file, contents, criteria, replacement) do
    """
    # File: `#{file}`
    ```
    #{Util.numbered_lines(contents)}
    ```

    # Criteria
    > #{criteria}

    # Replacement
    ```
    #{replacement}
    ```
    """
    |> get_completion()
    |> case do
      {:ok, response} ->
        response
        |> Jason.decode(keys: :atoms!)
        |> case do
          {:ok, %{error: reason}} when byte_size(reason) > 0 -> {:error, reason}
          {:ok, range} -> Hunk.new(file, range.start_line, range.end_line)
          {:error, reason} -> {:error, inspect(reason, pretty: true)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_completion(binary) ::
          {:ok, binary}
          | {:error, term}
  defp get_completion(msg) do
    AI.Completion.get(
      model: @model,
      response_format: @response_format,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(msg)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, %{response: response}} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_start(name, file, criteria, replacement) do
    UI.info("#{name} is locating a righteous hunk", """
    File: #{file}

    Criteria:
    #{criteria}

    Replacement:
    #{replacement}
    """)
  end

  defp log_success(name, hunk) do
    UI.info("#{name} found their hunk!", "#{hunk.file}:#{hunk.start_line}-#{hunk.end_line}")

    UI.debug("Hunk contents", """
    ```
    #{hunk.contents}
    ```
    """)
  end
end
