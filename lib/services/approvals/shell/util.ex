defmodule Services.Approvals.Shell.Util do
  @moduledoc """
  Utilities for secure shell command syntax validation. Detects potentially
  dangerous or risky patterns in a shell command, for use in preventing
  command injection and related vulnerabilities.
  """

  @ascii_pattern ~r/\||&&|\|\||;|>|<|`|\$\(|(?<!&)&(?!&)|<\(|>\(/u
  @unicode_homoglyph_pattern ~r/[；｜＆＞＜]/u
  @zero_width_space <<0x200B::utf8>>

  @doc """
  Returns true if any risky or dangerous shell syntax is detected:
  - Pipes, redirection, background, logical operators
  - Command or process substitution
  - Newlines, NUL bytes, or zero-width space in unquoted segments
  - Unbalanced quotes

  Example:
    iex> contains_risky_syntax?("ls -l")
    false

    iex> contains_risky_syntax?("ls | grep foo")
    true

    iex> contains_risky_syntax?("echo 'safe | quoted'")
    false
  """
  @spec contains_risky_syntax?(binary()) :: boolean()
  def contains_risky_syntax?(cmd) when is_binary(cmd) do
    with {:ok, parts} <- extract_unquoted_parts(cmd),
         false <- has_dangerous_characters?(cmd),
         false <- has_command_substitution_in_double_quotes?(cmd),
         false <- Enum.any?(parts, &contains_dangerous_unquoted_pattern?/1),
         false <- has_zero_width_space_in_unquoted?(parts) do
      false
    else
      _ -> true
    end
  end

  # ----------------------------------------------------------------------------
  # Unquoted segment extraction
  # ----------------------------------------------------------------------------
  defp extract_unquoted_parts(str), do: do_extract(str, [], :unquoted, [])

  defp do_extract(<<>>, acc, :unquoted, current) do
    {:ok,
     Enum.reverse(
       if current == [], do: acc, else: [IO.iodata_to_binary(Enum.reverse(current)) | acc]
     )}
  end

  defp do_extract(<<>>, _acc, _state, _current), do: {:error, :unbalanced_quotes}

  defp do_extract(<<"'", rest::binary>>, acc, :unquoted, current),
    do: do_extract(rest, flush_current(acc, current), :single_quoted, [])

  defp do_extract(<<"'", rest::binary>>, acc, :single_quoted, current),
    do: do_extract(rest, acc, :unquoted, current)

  defp do_extract(<<"\"", rest::binary>>, acc, :unquoted, current),
    do: do_extract(rest, flush_current(acc, current), :double_quoted, [])

  defp do_extract(<<"\"", rest::binary>>, acc, :double_quoted, current),
    do: do_extract(rest, acc, :unquoted, current)

  # Skip the next char in double quotes if escaped
  defp do_extract(<<"\\", _next, rest::binary>>, acc, :double_quoted, current),
    do: do_extract(rest, acc, :double_quoted, current)

  # Accumulate chars in unquoted part
  defp do_extract(<<char::utf8, rest::binary>>, acc, :unquoted, current),
    do: do_extract(rest, acc, :unquoted, [<<char::utf8>> | current])

  # Ignore chars inside quotes
  defp do_extract(<<_char::utf8, rest::binary>>, acc, quoted, current),
    do: do_extract(rest, acc, quoted, current)

  defp flush_current(acc, []), do: acc
  defp flush_current(acc, chars), do: [IO.iodata_to_binary(Enum.reverse(chars)) | acc]

  # ----------------------------------------------------------------------------
  # Pattern detection helpers
  # ----------------------------------------------------------------------------
  defp contains_dangerous_unquoted_pattern?(part) do
    Regex.match?(@ascii_pattern, part) or Regex.match?(@unicode_homoglyph_pattern, part)
  end

  defp has_dangerous_characters?(cmd) do
    String.contains?(cmd, ["\n", "\0", "<<", "$'"])
  end

  defp has_zero_width_space_in_unquoted?(parts) do
    Enum.any?(parts, &String.contains?(&1, @zero_width_space))
  end

  defp has_command_substitution_in_double_quotes?(cmd) do
    scan_dq_subst(cmd, :unquoted, "")
  end

  defp scan_dq_subst(<<>>, _state, _prev), do: false

  defp scan_dq_subst(<<"\"", rest::binary>>, :unquoted, prev) do
    if even_backslashes?(prev) do
      scan_dq_subst(rest, :double_quoted, "")
    else
      scan_dq_subst(rest, :unquoted, "")
    end
  end

  defp scan_dq_subst(<<"\"", rest::binary>>, :double_quoted, prev) do
    if even_backslashes?(prev) do
      scan_dq_subst(rest, :unquoted, "")
    else
      scan_dq_subst(rest, :double_quoted, "")
    end
  end

  defp scan_dq_subst(<<"'", rest::binary>>, :unquoted, prev) do
    if even_backslashes?(prev) do
      scan_dq_subst(rest, :single_quoted, "")
    else
      scan_dq_subst(rest, :unquoted, "")
    end
  end

  defp scan_dq_subst(<<"'", rest::binary>>, :single_quoted, prev) do
    if even_backslashes?(prev) do
      scan_dq_subst(rest, :unquoted, "")
    else
      scan_dq_subst(rest, :single_quoted, "")
    end
  end

  # Inside double quotes: only reject backtick-based substitution when
  # an unescaped backtick has a matching closing unescaped backtick.
  defp scan_dq_subst(<<"`", rest::binary>>, :double_quoted, prev) do
    if even_backslashes?(prev) and has_matching_backtick?(rest) do
      true
    else
      scan_dq_subst(rest, :double_quoted, "")
    end
  end

  defp scan_dq_subst(<<"$(", rest::binary>>, :double_quoted, prev) do
    if even_backslashes?(prev) do
      true
    else
      scan_dq_subst(rest, :double_quoted, "$")
    end
  end

  # Catch-all: accumulate previous chars for parity checks
  defp scan_dq_subst(<<c::utf8, rest::binary>>, state, prev) do
    scan_dq_subst(rest, state, prev <> <<c>>)
  end

  # Count trailing backslashes to determine escape parity
  defp even_backslashes?(str) do
    # Watch for empty or non-backslash tail...
    String.reverse(str)
    |> String.graphemes()
    |> Enum.take_while(&(&1 == "\\"))
    |> length()
    |> rem(2) == 0
  end

  # Scan the rest of the binary for an unescaped backtick.
  # Returns true if an unescaped closing backtick is found.
  defp has_matching_backtick?(binary) do
    case String.split(binary, "`", parts: 2) do
      [prefix, rest_bin] ->
        if even_backslashes?(prefix) do
          true
        else
          # escaped backtick: continue searching in the rest of the binary
          has_matching_backtick?(rest_bin)
        end

      _ ->
        false
    end
  end
end
