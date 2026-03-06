defmodule Patchwork do
  @moduledoc """
  Centralized exact-match text replacement engine. Provides validated string
  substitution with hashline prefix detection, typography normalization, and
  ambiguity checks. Used by both the file_edit_tool (coordinator's direct path)
  and the Patcher agent (natural language instruction path).
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @type replace_opts :: %{
          required(:old_string) => String.t(),
          required(:new_string) => String.t(),
          required(:replace_all) => boolean(),
          optional(atom()) => any()
        }

  @doc """
  Applies an exact string replacement to `contents` via `patch/2`.

  Validates that `old_string` does not contain hashline prefixes from
  file_contents_tool, falls back to typography-normalized matching when a
  byte-exact match fails, checks for ambiguous multiple occurrences, and
  optionally applies whitespace fitting.

  Returns `{:ok, new_contents}` or `{:error, reason}`.
  """
  @spec patch(binary, replace_opts) :: {:ok, binary} | {:error, String.t()}
  def patch(contents, %{old_string: old} = opts) do
    if byte_size(old) > 0 do
      with :ok <- check_hashline_prefixes(old, contents) do
        do_replace(contents, opts)
      end
    else
      do_replace(contents, opts)
    end
  end

  @doc """
  Simplified replacement for callers that don't need replace_all or file
  creation semantics. Returns `{:ok, new_contents}` or `{:error, reason}`.
  """
  @spec replace(binary, String.t(), String.t()) :: {:ok, binary} | {:error, String.t()}
  def replace(contents, old_string, new_string) do
    patch(contents, %{old_string: old_string, new_string: new_string, replace_all: false})
  end

  @doc """
  Hash-anchored replacement using `line:hash` identifiers for precise location
  and comprehension verification via `old_string`.

  Each element of `hashline_ids` is a `"line:hash"` string (e.g. `"42:a3f1"`)
  copied directly from file_contents_tool output. The line number provides
  unambiguous location (only one line 42), and the hash verifies the content
  hasn't changed since the file was read.

  The two-part contract serves different purposes:
  - `hashline_ids` (location): line numbers for unambiguous targeting, hashes
    for staleness detection. Immune to whitespace/indentation errors.
  - `old_string` (comprehension): forces the caller to read and reproduce
    the target region, catching misunderstandings before they produce bad
    replacement text

  The `old_string` comparison is whitespace-tolerant: leading whitespace is
  stripped from each line before comparing. The content must match, but
  indentation differences are forgiven.

  Returns `{:ok, new_contents}` or `{:error, reason}`.
  """
  @spec patch_by_hashes(binary, [String.t()], String.t(), String.t()) ::
          {:ok, binary} | {:error, String.t()}
  def patch_by_hashes(contents, hashline_ids, old_string, new_string)
      when is_binary(contents) and is_list(hashline_ids) and is_binary(old_string) and
             is_binary(new_string) do
    if hashline_ids == [] do
      {:error, "hashline_ids cannot be empty"}
    else
      file_lines = String.split(contents, "\n")

      with {:ok, {start_idx, end_idx}} <- resolve_hashline_ids(file_lines, hashline_ids) do
        line_count = end_idx - start_idx + 1
        old_lines = Enum.slice(file_lines, start_idx, line_count)

        with :ok <- verify_old_string(old_lines, old_string) do
          before_lines = Enum.take(file_lines, start_idx)
          after_lines = Enum.drop(file_lines, end_idx + 1)

          fitted =
            AI.Tools.File.Edit.WhitespaceFitter.fit(
              before_lines,
              old_lines,
              after_lines,
              new_string
            )

          new_lines = String.split(fitted, "\n")
          result_lines = before_lines ++ new_lines ++ after_lines
          {:ok, Enum.join(result_lines, "\n")}
        end
      end
    end
  end

  # Validates that old_string matches the hash-identified region by comparing
  # line content with leading whitespace stripped. This is the comprehension
  # check: it proves the caller read the target region correctly without
  # requiring byte-exact whitespace reproduction.
  #
  # Called after validate_hashes, so a mismatch here means the LLM miscopied
  # the content - not that the file changed. The error includes the actual file
  # content so the LLM can see exactly what it should have written.
  @spec verify_old_string([String.t()], String.t()) :: :ok | {:error, String.t()}
  defp verify_old_string(file_lines, old_string) do
    file_trimmed = Enum.map(file_lines, &String.trim_leading/1)
    old_trimmed = old_string |> String.split("\n") |> Enum.map(&String.trim_leading/1)

    if file_trimmed == old_trimmed do
      :ok
    else
      actual_content = Enum.join(file_lines, "\n")

      {:error,
       "old_string does not match the file content at the hash-identified location. " <>
         "The hashes are correct (the file has not changed), so this is a copy error " <>
         "in your old_string. The actual content at those lines is:\n" <>
         "```\n#{actual_content}\n```\n" <>
         "Copy this exactly (without hashline prefixes) into old_string."}
    end
  end

  # Parses a list of "line:hash" identifiers, validates that line numbers are
  # contiguous and in range, and verifies each line's content hash matches the
  # current file. Returns the 0-indexed start and end positions of the target
  # region, or a descriptive error.
  @spec resolve_hashline_ids([String.t()], [String.t()]) ::
          {:ok, {non_neg_integer, non_neg_integer}} | {:error, String.t()}
  defp resolve_hashline_ids(file_lines, hashline_ids) do
    file_line_count = length(file_lines)

    with {:ok, parsed} <- parse_hashline_ids(hashline_ids),
         :ok <- validate_contiguity(parsed),
         :ok <- validate_line_ranges(parsed, file_line_count),
         :ok <- validate_hashes(parsed, file_lines) do
      {first_line, _} = List.first(parsed)
      {last_line, _} = List.last(parsed)
      {:ok, {first_line - 1, last_line - 1}}
    end
  end

  # Parses each "line:hash" string into {line_number, hash} tuples.
  @doc """
  Parse and validate a list of hashline identifiers (`"line:hash"` format).
  Returns `{:ok, [{line_num, hash}]}` or `{:error, reason}`. Used both
  internally during patch application and externally by the Patcher agent
  to validate LLM responses before attempting a patch.
  """
  @spec parse_hashline_ids([String.t()]) ::
          {:ok, [{pos_integer, String.t()}]} | {:error, String.t()}
  def parse_hashline_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn
      id, {:ok, acc} when is_binary(id) ->
        case String.split(id, ":", parts: 2) do
          [line_str, hash] when byte_size(hash) > 0 ->
            with {line_num, ""} when line_num >= 1 <- Integer.parse(line_str),
                 true <- Regex.match?(~r/^[0-9a-f]{4}$/, hash) do
              {:cont, {:ok, [{line_num, hash} | acc]}}
            else
              false ->
                {:halt,
                 {:error,
                  "Invalid hashline identifier #{inspect(id)}: hash must be exactly 4 lowercase hex characters (e.g. \"a3f1\")"}}

              _ ->
                {:halt,
                 {:error,
                  "Invalid hashline identifier #{inspect(id)}: line number must be a positive integer"}}
            end

          _ ->
            {:halt,
             {:error,
              "Invalid hashline identifier #{inspect(id)}: expected \"line:hash\" format (e.g. \"42:a3f1\")"}}
        end

      id, {:ok, _acc} ->
        {:halt,
         {:error,
          "Invalid hashline identifier #{inspect(id)}: expected a string, got #{inspect(id)}"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # Validates that parsed line numbers form a contiguous sequence (e.g. 5,6,7).
  @spec validate_contiguity([{pos_integer, String.t()}]) :: :ok | {:error, String.t()}
  defp validate_contiguity(parsed) do
    line_nums = Enum.map(parsed, fn {line, _} -> line end)
    expected = Enum.to_list(List.first(line_nums)..List.last(line_nums))

    if line_nums == expected do
      :ok
    else
      {:error,
       "Line numbers must be contiguous. Got #{inspect(line_nums)} " <>
         "but expected #{inspect(expected)}."}
    end
  end

  # Validates that all line numbers are within the file's line count.
  @spec validate_line_ranges([{pos_integer, String.t()}], non_neg_integer) ::
          :ok | {:error, String.t()}
  defp validate_line_ranges(parsed, file_line_count) do
    {last_line, _} = List.last(parsed)

    if last_line <= file_line_count do
      :ok
    else
      {:error, "Line #{last_line} is out of range. The file has #{file_line_count} lines."}
    end
  end

  # Verifies each line's content hash matches the current file, catching edits
  # made since the file was last read.
  @spec validate_hashes([{pos_integer, String.t()}], [String.t()]) :: :ok | {:error, String.t()}
  defp validate_hashes(parsed, file_lines) do
    parsed
    |> Enum.reduce_while(:ok, fn {line_num, expected_hash}, :ok ->
      actual_line = Enum.at(file_lines, line_num - 1)
      actual_hash = Util.line_hash(actual_line)

      if actual_hash == expected_hash do
        {:cont, :ok}
      else
        preview = String.slice(actual_line, 0, 40)

        {:halt,
         {:error,
          "Hash mismatch at line #{line_num}: expected #{inspect(expected_hash)} " <>
            "but file has #{inspect(actual_hash)} (#{inspect(preview)}). " <>
            "The file may have changed since you last read it. " <>
            "Please re-read the file and retry."}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Core replacement logic
  # ---------------------------------------------------------------------------

  defp do_replace(contents, %{old_string: old, new_string: new, replace_all: replace_all} = opts) do
    cond do
      # File creation case: empty old_string with empty contents
      byte_size(old) == 0 and byte_size(contents) == 0 ->
        {:ok, new}

      # Empty old_string with non-empty contents (invalid)
      byte_size(old) == 0 ->
        {:error, "old_string cannot be empty when editing existing content"}

      # Normal replacement: try byte-exact first, then fall back through
      # progressively fuzzier matching strategies. Each returns the original
      # file substring so the replacement operates on actual file bytes.
      not String.contains?(contents, old) ->
        file_old =
          find_typographic_match(contents, old) ||
            find_whitespace_normalized_match(contents, old)

        case file_old do
          nil ->
            {:error, "String not found in file: #{inspect(old)}"}

          match ->
            __MODULE__.patch(contents, %{opts | old_string: match})
        end

      replace_all ->
        {:ok, String.replace(contents, old, new)}

      true ->
        replace_single(contents, old, new)
    end
  end

  # Exactly-one-occurrence replacement with ambiguity detection and optional
  # whitespace fitting.
  defp replace_single(contents, old, new) do
    parts = String.split(contents, old)

    case parts do
      [before, after_part] ->
        no_fitting? =
          case Util.Env.fetch_env("FNORD_NO_FITTING") do
            {:ok, v} when v in ["true", "True", "1"] -> true
            _ -> false
          end

        replacement =
          if no_fitting? do
            new
          else
            AI.Tools.File.Edit.WhitespaceFitter.fit(
              String.split(before, "\n", trim: false),
              String.split(old, "\n", trim: false),
              String.split(after_part, "\n", trim: false),
              new
            )
          end

        {:ok, before <> replacement <> after_part}

      _ ->
        count = length(parts) - 1

        {:error,
         "String appears #{count} times in file. Set replace_all: true to replace all occurrences"}
    end
  end

  # ---------------------------------------------------------------------------
  # Hashline prefix detection
  # ---------------------------------------------------------------------------

  # Validates that old_string does not contain hashline prefixes accidentally
  # copied from file_contents_tool output. Uses a three-step check:
  # 1. Regex finds candidate `<line>:<hash>|` patterns at line starts
  # 2. If the literal pattern exists in the file contents, it's real data - skip
  # 3. Otherwise, check if the line number + hash match the current file to
  #    distinguish "copied prefixes" from "stale file reference"
  @hashline_prefix_pattern ~r/^(\d+):([0-9a-f]{4})\|(.*)$/m

  @spec check_hashline_prefixes(binary, binary) :: :ok | {:error, String.t()}
  defp check_hashline_prefixes(old_string, contents) do
    @hashline_prefix_pattern
    |> Regex.scan(old_string)
    |> Enum.reduce_while(:ok, fn [full_match, line_num_str, hash, line_text], :ok ->
      if String.contains?(contents, full_match) do
        # The literal text (e.g. "42:a3|data") exists in the file - it's real
        # file content (CSV, config, etc.), not an accidental hashline prefix.
        {:cont, :ok}
      else
        # The literal doesn't exist in the file, so this looks like a hashline
        # prefix. Verify against the current file to give a precise error.
        line_num = String.to_integer(line_num_str)
        file_lines = String.split(contents, "\n")

        cond do
          # Line number in range and hash matches - agent copied prefixes
          line_num >= 1 and
            line_num <= length(file_lines) and
              Util.line_hash(Enum.at(file_lines, line_num - 1)) == hash ->
            {:halt,
             {:error,
              """
              old_string contains hashline prefixes (e.g. "#{line_num}:#{hash}|#{String.slice(line_text, 0, 20)}"). \
              The file_contents_tool adds these for reference, but old_string must contain \
              the raw file text without them. Strip the "<line>:<hash>|" prefix from each line.
              """}}

          # Line number/hash don't match - file has changed since it was read
          true ->
            {:halt,
             {:error,
              """
              old_string appears to contain hashline identifiers (e.g. "#{line_num}:#{hash}|") \
              that do not match the current file contents. The file may have changed since you \
              last read it. Please re-read the file with file_contents_tool and retry your edit.
              """}}
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Typography normalization
  # ---------------------------------------------------------------------------

  # When an exact match fails, the LLM may have sent ASCII punctuation while
  # the file contains typographic equivalents (smart quotes, em dashes, etc.).
  # Normalize both sides and, if a match is found, return the original file
  # substring so the replacement operates on actual file bytes.
  @spec find_typographic_match(binary, binary) :: binary | nil
  defp find_typographic_match(contents, old) do
    normalized_old = normalize_typography(old)
    normalized_contents = normalize_typography(contents)

    # Short-circuit: if normalizing both sides doesn't produce a match,
    # typography isn't the issue.
    if not String.contains?(normalized_contents, normalized_old) do
      nil
    else
      # Build a mapping from each grapheme in the original content to its
      # normalized form, tracking cumulative normalized-string offsets so we
      # can map a match position in the normalized string back to a span of
      # original graphemes.
      grapheme_map =
        contents
        |> String.graphemes()
        |> Enum.reduce({[], 0}, fn g, {acc, norm_offset} ->
          norm_g = normalize_typography(g)
          norm_len = String.length(norm_g)
          {[{g, norm_offset, norm_len} | acc], norm_offset + norm_len}
        end)
        |> then(fn {acc, _} -> Enum.reverse(acc) end)

      # Find where the normalized old string starts in the normalized contents
      case :binary.match(normalized_contents, normalized_old) do
        {norm_start, norm_match_len} ->
          norm_end = norm_start + norm_match_len

          # Collect original graphemes whose normalized range overlaps the match
          grapheme_map
          |> Enum.filter(fn {_g, offset, len} ->
            offset >= norm_start and offset + len <= norm_end
          end)
          |> Enum.map(fn {g, _, _} -> g end)
          |> Enum.join()

        :nomatch ->
          nil
      end
    end
  end

  @typographic_replacements [
    # Smart double quotes
    {"\u201C", "\""},
    {"\u201D", "\""},
    # Smart single quotes / apostrophes
    {"\u2018", "'"},
    {"\u2019", "'"},
    # Em dash, en dash
    {"\u2014", "--"},
    {"\u2013", "-"},
    # Ellipsis
    {"\u2026", "..."}
  ]

  @spec normalize_typography(binary) :: binary
  defp normalize_typography(text) do
    Enum.reduce(@typographic_replacements, text, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  # ---------------------------------------------------------------------------
  # Whitespace-normalized matching
  # ---------------------------------------------------------------------------

  # When both byte-exact and typography-normalized matching fail, the LLM may
  # have the right content but wrong leading whitespace (tabs vs spaces, wrong
  # indent depth). This normalizer strips all leading whitespace from each line
  # on both sides, finds a match in that normalized space, then maps back to
  # the original file substring.
  #
  # This is deliberately line-oriented: we split both the file contents and
  # old_string into lines, normalize each line by stripping leading whitespace,
  # then search for the normalized old_string lines as a contiguous subsequence
  # in the normalized file lines. This avoids false positives from partial
  # intra-line matches that a flat string approach would allow.
  @spec find_whitespace_normalized_match(binary, binary) :: binary | nil
  defp find_whitespace_normalized_match(contents, old) do
    file_lines = String.split(contents, "\n")
    old_lines = String.split(old, "\n")

    # Don't attempt whitespace matching on single-token or empty strings where
    # leading whitespace is unlikely to be the problem.
    if length(old_lines) < 2 do
      nil
    else
      normalized_file = Enum.map(file_lines, &String.trim_leading/1)
      normalized_old = Enum.map(old_lines, &String.trim_leading/1)
      old_len = length(normalized_old)

      # Slide a window of old_len over the normalized file lines, collecting
      # all positions where the normalized content matches.
      matches =
        normalized_file
        |> Enum.chunk_every(old_len, 1, :discard)
        |> Enum.with_index()
        |> Enum.filter(fn {chunk, _idx} -> chunk == normalized_old end)
        |> Enum.map(fn {_chunk, idx} -> idx end)

      case matches do
        [idx] ->
          # Unique match: extract the original file lines at that position
          file_lines
          |> Enum.slice(idx, old_len)
          |> Enum.join("\n")

        _ ->
          # Zero or multiple matches: ambiguous, bail out
          nil
      end
    end
  end
end
