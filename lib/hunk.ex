defmodule Hunk do
  @moduledoc """
  Represents a hunk of text from a file, defined by a range of lines. Provides
  functionality to create, validate, stage, and apply changes to the hunk.
  """

  defstruct [
    :file,
    :start_line,
    :end_line,
    :contents,
    :hash,
    :temp
  ]

  @typedoc """
  Represents a hunk of text from a file, defined by a range of lines. Lines are
  1-based indices, inclusive.
  """
  @type t :: %__MODULE__{
          file: binary,
          start_line: non_neg_integer,
          end_line: non_neg_integer,
          contents: binary,
          hash: binary,
          temp: binary | nil
        }

  defimpl String.Chars, for: Hunk do
    def to_string(%Hunk{file: file, start_line: start_line, end_line: end_line}) do
      "#{file}:#{start_line}...#{end_line}"
    end
  end

  @doc """
  Creates a new `Hunk` struct for the specified file and line range. The
  `start_line` and `end_line` are 1-based indices, inclusive.
  """
  def new(file, start_line, end_line) do
    with {:ok, hash} <- md5(file),
         {:ok, contents} <- find_contents(file, start_line, end_line) do
      {:ok,
       %Hunk{
         file: file,
         start_line: start_line,
         end_line: end_line,
         contents: contents,
         hash: hash,
         temp: nil
       }}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `true` if the file has changed since the `Hunk` was created.
  """
  def is_stale?(hunk) do
    case md5(hunk.file) do
      {:ok, current_hash} -> current_hash != hunk.hash
      {:error, _} -> true
    end
  end

  @doc """
  Returns `true` if the hunk is stale AND the file contents at the line range
  have changed since the hunk was created, indicating that the line range no
  longer represents what it did when the Hunk was created.
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
  Returns `true` if the hunk is staged, meaning it has a temporary file
  created for staging changes. See `stage_changes/2`.
  """
  def is_staged?(hunk) do
    is_binary(hunk.temp)
  end

  @doc """
  Returns the contents of the hunk with `context_lines` lines of context before
  and after the hunk. The `pre_anchor` and `post_anchor` are inserted between
  the context and the hunk contents to provide a visual anchor for where
  changes are to be applied.
  """
  def change_context(hunk, context_lines, pre_anchor, post_anchor) do
    if is_valid?(hunk) do
      with {:ok, contents} <- File.read(hunk.file) do
        lines = String.split(contents, "\n", trim: false)

        before_start_idx = max(hunk.start_line - context_lines - 1, 0)
        lines_before = Enum.slice(lines, before_start_idx, context_lines)

        after_start_idx = hunk.end_line
        lines_after = Enum.slice(lines, after_start_idx, context_lines)

        pre_anchor_lines =
          if pre_anchor != "" do
            [pre_anchor]
          else
            []
          end

        post_anchor_lines =
          if post_anchor != "" do
            [post_anchor]
          else
            []
          end

        within_lines =
          lines
          |> Enum.slice(
            hunk.start_line - 1,
            hunk.end_line - hunk.start_line + 1
          )

        context =
          [
            lines_before,
            pre_anchor_lines,
            within_lines,
            post_anchor_lines,
            lines_after,
            # Ensure we end with a newline
            [""]
          ]
          |> Enum.concat()
          |> Enum.join("\n")

        {:ok, context}
      end
    else
      {:error, :stale}
    end
  end

  @doc """
  Stages changes to the hunk by creating a temporary file with the specified
  replacement content. The temporary file will contain the original file's
  contents with the specified replacement applied within the specified line
  range.
  """
  def stage_changes(hunk, replacement) do
    with {:ok, temp} <- Briefly.create(),
         {:ok, contents} <- File.read(hunk.file),
         :ok <- File.write(temp, contents) do
      # Special-case: empty file & zero-length hunk -> write replacement
      # verbatim.
      if contents == "" && hunk.start_line == 0 && hunk.end_line == 0 do
        File.write(temp, replacement)
      else
        lines = String.split(contents, "\n")
        # Clamp counts to avoid negative indices
        before_count = max(hunk.start_line - 1, 0)
        after_count = max(hunk.end_line, 0)

        lines_before = Enum.take(lines, before_count)
        lines_after = Enum.drop(lines, after_count)
        lines_within = String.split(replacement, "\n")

        new_contents =
          [lines_before, lines_within, lines_after]
          |> List.flatten()
          |> Enum.join("\n")

        File.write(temp, new_contents)
      end

      {:ok, %Hunk{hunk | temp: temp}}
    end
  end

  @doc """
  Builds a diff of the staged changes in the hunk. If the hunk is not staged,
  it returns an error.
  """
  def build_diff(hunk) do
    if is_staged?(hunk) do
      "diff"
      |> System.cmd(
        [
          "-u",
          "-L",
          "ORIGINAL",
          "-L",
          "MODIFIED",
          hunk.file,
          hunk.temp
        ],
        stderr_to_stdout: true
      )
      |> case do
        {_, 0} ->
          {:ok, "No differences found."}

        {output, 1} ->
          {:ok, String.trim_trailing(output)}

        {error, code} ->
          {:error, "diff command failed with code #{code}: #{String.trim_trailing(error)}"}
      end
    else
      {:error, :not_staged}
    end
  end

  @doc """
  Applies the staged changes in the hunk to the original file. If the `hunk` is
  not staged, it returns an error. After applying changes, the returned `hunk`
  is no longer staged and should be considered stale.
  """
  def apply_staged_changes(hunk) do
    if is_staged?(hunk) do
      with {:ok, contents} <- File.read(hunk.temp),
           :ok <- File.write(hunk.file, contents) do
        # Clean up temporary file after applying changes. We don't actually
        # care if it errors out. Briefly will handle cleanup on exit. This just
        # tidies up the disk so they don't accumulate as badly.
        File.rm(hunk.temp)
        {:ok, %{hunk | temp: nil}}
      end
    else
      {:error, :not_staged}
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------
  defp md5(file) do
    with {:ok, contents} <- File.read(file) do
      :crypto.hash(:md5, contents)
      |> Base.encode16(case: :lower)
      |> then(&{:ok, &1})
    end
  end

  def find_contents(hunk) do
    find_contents(hunk.file, hunk.start_line, hunk.end_line)
  end

  def find_contents(file, start_line, end_line) do
    with {:ok, contents} <- File.read(file) do
      lines = String.split(contents, "\n", trim: false)

      cond do
        contents == "" ->
          {:ok, ""}

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
