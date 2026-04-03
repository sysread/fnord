defmodule AI.Agent.Code.Patcher do
  # ----------------------------------------------------------------------------
  # Constants
  # ----------------------------------------------------------------------------
  @model AI.Model.coding()

  @max_retries 2

  @prompt """
  # Synopsis
  You are the Patcher, an AI Agent that applies changes to a file.
  You are an expert programmer and can understand the syntax and semantics of the file's contents.
  You are clever enough to DWIM and interpret the intent of changes requested by the Coordinating Agent, adapting them to the file's context.
  You will be provided with the contents of a file and a series of changes to apply to the file.
  If you cannot apply a change, you must return an error.
  NEVER delete comments or documentation unless explicitly instructed to do so.
  ALWAYS follow the style and formatting of the code already present in the file.

  # Line Identifiers
  Each line is prefixed with a hashline identifier: a line number, a colon, a 4-character content hash, then a pipe (`|`) character, followed *immediately* by the line text (no additional whitespace).
  The content hash is a fingerprint of the line's text content.
  Use the hash to verify you are targeting the correct lines; if the hash does not match the content you expect, the file may have changed since you last read it.

  These hashlines:
  ```
  1:a3f1|This is the first line of the file.
  2:f10e|  - This is the second line of the file.
  ```

  Equate to this content:
  ```
  This is the first line of the file.
    - This is the second line of the file.
  ```

  # Process
  You will be provided with a file's contents and each change in turn.
  Your job is to produce a `hashes` / `old_string` / `new_string` triple:
  1. Identify the contiguous region of lines to change using hashline identifiers.
  2. Collect the full `line:hash` identifier from each line in that region, in order, and return them as the `hashes` array.
     For example, from `42:a3f1|text`, the identifier is `"42:a3f1"`.
     Every line in the contiguous region must be included, even lines you are not changing.
  3. Copy the text of those lines into `old_string`, without hashline prefixes.
     This proves you read the target region correctly.
     Copy it character for character from the file content shown to you (stripping only the `<line>:<hash>|` prefix from each line).
  4. Produce the `new_string` with the requested changes applied to that region.
     Whitespace fitting is applied automatically, so focus on getting the content right rather than matching exact indentation.
  5. Do not include the hashline prefixes (e.g. `1:a3f1|`) in `old_string` or `new_string`.

  # Language Agnostic Operation
  This tool works with any type of text file (code, configuration, plain text, etc.).
  Do not assume any specific programming language, syntax, or tooling is available.
  Focus on making the requested textual changes accurately without syntax validation.

  # Best practices
  - Include exactly the lines that need to change plus minimal surrounding context to avoid hash collisions.
    For single-line changes, include 1-2 neighboring lines.
  - For deletion, set new_string to an empty string.
  - Generate linear, atomic patches; avoid complex nested conditionals in a single patch.
  - If a requested change implies multiple steps, propose sequential, small patches rather than nesting logic.

  # Verification (REQUIRED before returning your patch)
  Before returning your patch, verify your output by walking through these steps:
  1. State which lines you are targeting and why (referencing hashline IDs).
  2. Confirm that each `line:hash` identifier in your `hashes` array matches the corresponding hashline prefix in the file contents.
  3. Confirm that `old_string` is copied exactly from the file content (without hashline prefixes, no modifications, no truncation).
  4. Confirm that `new_string` contains the correct replacement text.
  If your verification reveals a mismatch, fix the patch before returning.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "patch",
      description: """
      A JSON object describing a hash-anchored replacement to apply to the
      file. If you are unable to produce a patch for the requested change, set
      the `error` field to a descriptive error message, leave `hashes` empty,
      and set `old_string` and `new_string` to empty strings.
      """,
      schema: %{
        type: "object",
        required: ["error", "hashes", "old_string", "new_string"],
        additionalProperties: false,
        properties: %{
          error: %{
            type: "string",
            description: """
            An error message if the patch could not be generated. If you were
            able to come up with a patch, this MUST be an empty string.
            """
          },
          hashes: %{
            type: "array",
            items: %{type: "string"},
            description: """
            Ordered list of `line:hash` identifiers for the contiguous region
            of lines to replace. Collect these from the hashline prefixes in
            the file contents (e.g. from "42:a3f1|text", the identifier is
            "42:a3f1"). Every line in the contiguous region must be included.
            If `error` is set, this MUST be an empty array.
            """
          },
          old_string: %{
            type: "string",
            description: """
            The text content of the lines identified by hashes, copied from the
            file WITHOUT hashline prefixes. This is a comprehension check that
            proves you read the target region correctly. Copy it character for
            character from the file. If `error` is set, this MUST be an empty
            string.
            """
          },
          new_string: %{
            type: "string",
            description: """
            The replacement text for the identified line range. Whitespace
            fitting is applied automatically to match surrounding indentation.
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
    :retry_counts,
    :error_context,
    :context
  ]

  @type t :: %__MODULE__{
          agent: AI.Agent.t(),
          file: binary,
          changes: list(binary),
          contents: binary,
          tools: map(),
          retry_counts: map(),
          error_context: %{response: binary, reason: binary} | nil,
          context: binary | nil
        }

  @spec new(map) :: {:ok, t} | {:error, binary}
  defp new(opts) do
    with {:ok, agent} <- required_arg(opts, :agent),
         {:ok, file} <- required_arg(opts, :file),
         {:ok, changes} <- required_arg(opts, :changes),
         {:ok, contents} <- read_file(file) do
      UI.report_from(agent.name, "Working on", file)

      # The Patcher produces structured JSON patches via response_format -
      # it should NOT have shell access, which tempts the LLM into sed/awk
      # workarounds instead of using hash-anchored edits.
      tools = %{"notify_tool" => AI.Tools.Notify}

      {:ok,
       %__MODULE__{
         agent: agent,
         file: file,
         changes: changes,
         contents: contents,
         tools: tools,
         retry_counts: %{},
         error_context: nil,
         context: Map.get(opts, :context)
       }}
    end
  end

  defp read_file(path) do
    path
    |> AI.Tools.get_file_contents()
    |> case do
      {:ok, contents} -> {:ok, contents}
      {:error, _} -> {:ok, ""}
    end
  end

  @spec apply_changes(t) :: {:ok, t} | {:error, binary}
  defp apply_changes(%{changes: []} = state), do: {:ok, state}

  defp apply_changes(%{changes: [change | remaining], contents: contents} = state) do
    UI.report_from(state.agent.name, "Patching #{AI.Tools.display_path(state.file)}", change)

    numbered = Util.numbered_lines(contents)
    messages = build_messages(state, numbered, change)

    AI.Agent.get_completion(state.agent,
      model: @model,
      response_format: @response_format,
      log_msgs: false,
      log_tool_calls: true,
      toolbox: state.tools,
      messages: messages
    )
    |> case do
      {:error, reason} ->
        retry_or_fail(state, change, nil, reason)

      {:ok, %{response: response}} ->
        case parse_patch_response(response) do
          {:ok, {hashes, old_string, new_string}} ->
            case Patchwork.patch_by_hashes(contents, hashes, old_string, new_string) do
              {:ok, updated_contents} ->
                # Clear error_context on success before processing remaining
                # changes - each change starts with a clean slate.
                %{state | changes: remaining, contents: updated_contents, error_context: nil}
                |> apply_changes()

              {:error, reason} ->
                retry_or_fail(state, change, response, reason)
            end

          {:error, reason} ->
            retry_or_fail(state, change, response, reason)
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Message construction
  #
  # Builds the message list for the LLM. On first attempt, this is a simple
  # system + user pair. On retry, the previous failed response and error
  # feedback are appended so the LLM can learn from its mistake instead of
  # blindly repeating it.
  # ----------------------------------------------------------------------------
  defp build_messages(state, numbered_contents, change) do
    context_section =
      if state.context do
        """
        Background context from the coordinating agent:
        #{state.context}

        ---

        """
      else
        ""
      end

    base = [
      AI.Util.system_msg(AI.Util.project_context()),
      AI.Util.system_msg(@prompt),
      AI.Util.user_msg("""
      #{context_section}File contents:
      ```
      #{numbered_contents}
      ```

      Please apply the following change to the file contents above:
      #{change}
      """)
    ]

    case state.error_context do
      nil ->
        base

      %{response: response, reason: reason} ->
        base ++
          [
            AI.Util.assistant_msg(response),
            AI.Util.user_msg("""
            Your previous patch attempt failed with the following error:
            #{reason}

            Please re-examine the file contents and try again.
            """)
          ]
    end
  end

  # ----------------------------------------------------------------------------
  # Retry logic
  #
  # Increments the retry counter for this change and re-enters apply_changes
  # with error context so the LLM receives feedback about what went wrong.
  # If retries are exhausted, returns the error to the coordinator.
  # ----------------------------------------------------------------------------
  defp retry_or_fail(state, change, response, reason) do
    attempts = Map.get(state.retry_counts, change, 0) + 1

    if attempts <= @max_retries do
      error_context =
        if response do
          %{response: response, reason: inspect(reason, pretty: true, limit: :infinity)}
        else
          nil
        end

      %{
        state
        | retry_counts: Map.put(state.retry_counts, change, attempts),
          error_context: error_context
      }
      |> apply_changes()
    else
      error_response(change, reason)
    end
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

  # Parses the LLM JSON response into a {hashes, old_string, new_string} tuple.
  # Validates structure and ensures hashes is a non-empty list.
  defp parse_patch_response(json) do
    case SafeJson.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        # The model may wrap the result in a "patch" key or return it flat
        patch = Map.get(decoded, "patch", decoded)

        case patch do
          %{"error" => error} when is_binary(error) and byte_size(error) > 0 ->
            {:error, error}

          %{"hashes" => hashes, "old_string" => old, "new_string" => new}
          when is_list(hashes) and is_binary(old) and is_binary(new) ->
            if hashes == [] do
              {:error, "Invalid patch: hashes cannot be empty"}
            else
              # Validate that each hash is a well-formed "line:hash" identifier
              # before we even attempt to apply the patch. Catches fabricated
              # hashes early (e.g. LLMs inventing "f6xf" instead of real hex).
              case Patchwork.parse_hashline_ids(hashes) do
                {:ok, _parsed} -> {:ok, {hashes, old, new}}
                {:error, reason} -> {:error, reason}
              end
            end

          _ ->
            {:error, "Invalid patch structure: expected hashes array, old_string, and new_string"}
        end

      {:ok, _} ->
        {:error, "Invalid patch structure: decoded JSON response is not an object"}

      {:error, error} ->
        {:error, "Invalid patch structure: #{inspect(error)}"}
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
