defmodule Hunk do
  defstruct [
    :file,
    :start_line,
    :end_line,
    :contents,
    :hash
  ]

  @context_lines 10

  @type t :: %__MODULE__{
          file: binary,
          start_line: non_neg_integer,
          end_line: non_neg_integer,
          contents: binary,
          hash: binary
        }

  @doc """
  Creates a new Hunk struct for the specified file and line range.
  The file must exist, and the line range must be valid.
  Returns `{:ok, hunk}` on success, or an error tuple on failure.
  """
  @spec new(binary, non_neg_integer, non_neg_integer) ::
          {:ok, t}
          | {:error, :invalid_start_line}
          | {:error, :invalid_end_line}
          | {:error, :end_line_exceeds_file_length}
          | {:error, :file_not_found}
  def new(file, start_line, end_line) do
    with {:ok, hash} <- md5(file),
         {:ok, contents} <- find_contents(file, start_line, end_line) do
      {:ok,
       %Hunk{
         file: file,
         start_line: start_line,
         end_line: end_line,
         contents: contents,
         hash: hash
       }}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns a snippet of the hunk's file with context around the hunk's contents.
  The snippet includes the specified pre and post anchors, and a number of
  context lines before and after the hunk.
  """

  @spec with_context(t, binary, binary, non_neg_integer) ::
          {:ok, binary}
          | {:error, :not_found}
          | {:error, :file_not_found}
          | {:error, File.posix()}
  def with_context(hunk, pre_anchor, post_anchor, context_lines \\ @context_lines) do
    with {:ok, file_contents} <- File.read(hunk.file),
         {pos, _len} <- :binary.match(file_contents, hunk.contents) do
      # Compute the starting line (0-based) of the match in the original file.
      start_line_idx = :binary.matches(binary_part(file_contents, 0, pos), "\n") |> length()

      lines = String.split(file_contents, "\n", trim: false)
      from = max(start_line_idx - context_lines, 0)
      to = min(start_line_idx + context_lines, length(lines) - 1)

      # Slice context from the original file (no anchors yet).
      snippet_lines = Enum.slice(lines, from, to - from + 1)

      # Figure out where to insert anchors relative to the slice.
      within_idx = start_line_idx - from

      contents_line_count =
        hunk.contents
        |> String.split("\n", trim: false)
        |> length()

      # Insert anchors as standalone lines: pre before the first line of the hunk,
      # post after the last line of the hunk.
      snippet_lines =
        snippet_lines
        |> List.insert_at(within_idx, pre_anchor)
        |> List.insert_at(within_idx + contents_line_count + 1, post_anchor)

      snippet = Enum.join(snippet_lines, "\n")
      # Ensure trailing newline to match the test's heredoc expectation.
      snippet = if String.ends_with?(snippet, "\n"), do: snippet, else: snippet <> "\n"

      {:ok, snippet}
    else
      :nomatch -> {:error, :not_found}
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `true` if the hunk is stale, meaning the file's contents have changed
  since the hunk was created.
  """
  def is_stale?(hunk) do
    case md5(hunk.file) do
      {:ok, current_hash} -> current_hash != hunk.hash
      {:error, _} -> true
    end
  end

  @doc """
  Returns `true` if the hunk is:
  1. Not stale
  2. Stale, but the contents at the line range have not changed
  """
  def is_valid?(hunk) do
    case is_stale?(hunk) do
      false ->
        true

      true ->
        case find_contents(hunk.file, hunk.start_line, hunk.end_line) do
          {:ok, contents} -> contents == hunk.contents
          {:error, _} -> false
        end
    end
  end

  @doc """
  Replaces the contents of the hunk's file at the specified line range with
  the provided replacement text. The replacement will completely replace all
  content within the start and end lines, inclusive.
  """
  @spec replace_in_file(t, binary) ::
          :ok
          | {:error, :file_not_found}
          | {:error, :hunk_is_stale}
  def replace_in_file(hunk, replacement) do
    cond do
      !File.exists?(hunk.file) ->
        {:error, :file_not_found}

      !is_valid?(hunk) ->
        {:error, :invalid_hunk_contents}

      is_stale?(hunk) ->
        {:error, :hunk_is_stale}

      true ->
        with {:ok, contents} <- File.read(hunk.file) do
          lines = String.split(contents, "\n")
          lines_before = Enum.take(lines, hunk.start_line - 1)
          lines_after = Enum.drop(lines, hunk.end_line)
          lines_within = String.split(replacement, "\n")
          new_contents = Enum.join(lines_before ++ lines_within ++ lines_after, "\n")

          File.write(hunk.file, new_contents)
        else
          _ -> {:error, :file_not_found}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # Internal Functions
  # ----------------------------------------------------------------------------
  @spec md5(binary) :: {:ok, binary} | {:error, term}
  defp md5(file) do
    with {:ok, contents} <- File.read(file) do
      :crypto.hash(:md5, contents)
      |> Base.encode16(case: :lower)
      |> then(&{:ok, &1})
    end
  end

  def find_contents(file, start_line, end_line) do
    with {:ok, contents} <- File.read(file) do
      lines = String.split(contents, "\n", trim: false)

      cond do
        start_line < 1 ->
          {:error, :invalid_start_line}

        end_line < start_line ->
          {:error, :invalid_end_line}

        end_line > length(lines) ->
          {:error, :end_line_exceeds_file_length}

        true ->
          lines
          |> Enum.slice(start_line - 1, end_line - start_line + 1)
          |> Enum.join("\n")
          |> then(&{:ok, &1})
      end
    else
      _ -> {:error, :file_not_found}
    end
  end
end
