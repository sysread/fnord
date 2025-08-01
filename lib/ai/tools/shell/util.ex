defmodule AI.Tools.Shell.Util do
  @moduledoc """
  Utility functions for shell command validation and security checking.

  This module provides functions to analyze shell commands for potentially
  dangerous syntax that could be used for command injection or other
  security vulnerabilities.
  """

  @doc """
  Checks if a shell command contains disallowed syntax.

  Returns `true` if the command contains dangerous patterns like:
  - Pipes, redirection, or logical operators
  - Command substitution or process substitution
  - Unbalanced quotes or shell escape sequences
  - Dangerous characters like newlines, NUL bytes, or zero-width spaces

  ## Examples

      iex> AI.Tools.Shell.Util.contains_disallowed_syntax?("ls -l")
      false
      
      iex> AI.Tools.Shell.Util.contains_disallowed_syntax?("ls | grep foo")
      true
      
      iex> AI.Tools.Shell.Util.contains_disallowed_syntax?("echo 'safe | quoted'")
      false
  """
  @spec contains_disallowed_syntax?(binary()) :: boolean()
  def contains_disallowed_syntax?(cmd) when is_binary(cmd) do
    try do
      check_dangerous_patterns(cmd)
    rescue
      _ -> true
    catch
      :disallowed -> true
      _ -> true
    else
      false -> false
      true -> true
    end
  end

  defp check_dangerous_patterns(cmd) do
    # Check for various dangerous patterns
    has_dangerous_characters?(cmd) or
      has_unbalanced_quotes?(cmd) or
      has_cmd_substitution_in_double_quotes?(cmd) or
      (
        unquoted_parts = extract_unquoted_parts(cmd, [], :unquoted, "")

        Enum.any?(unquoted_parts, fn part ->
          contains_dangerous_unquoted_pattern?(part)
        end)
      )
  end

  defp has_dangerous_characters?(cmd) do
    # Check for dangerous characters that should be rejected regardless of context
    # Here-document
    # Shell escape sequences
    String.contains?(cmd, ["\n", "\0"]) or
      String.contains?(cmd, "<<") or
      String.contains?(cmd, "$'") or
      has_zero_width_space_in_unquoted?(cmd)
  end

  defp has_zero_width_space_in_unquoted?(cmd) do
    # Check if zero-width space appears in unquoted parts
    try do
      unquoted_parts = extract_unquoted_parts(cmd, [], :unquoted, "")

      Enum.any?(unquoted_parts, fn part ->
        String.contains?(part, <<0x200B::utf8>>)
      end)
    catch
      :unbalanced_quotes ->
        # If quotes are unbalanced, just check if ZWSP exists anywhere (conservative)
        String.contains?(cmd, <<0x200B::utf8>>)
    end
  end

  defp has_unbalanced_quotes?(cmd) do
    try do
      extract_unquoted_parts(cmd, [], :unquoted, "")
      false
    catch
      :unbalanced_quotes -> true
    end
  end

  defp has_cmd_substitution_in_double_quotes?(cmd) do
    check_double_quoted_cmd_subst(cmd, :unquoted)
  end

  defp check_double_quoted_cmd_subst("", _state), do: false

  defp check_double_quoted_cmd_subst(<<char::utf8, rest::binary>>, state) do
    case {state, char} do
      {:unquoted, ?'} ->
        check_double_quoted_cmd_subst(rest, :single_quoted)

      {:unquoted, ?"} ->
        check_double_quoted_cmd_subst(rest, :double_quoted)

      {:single_quoted, ?'} ->
        check_double_quoted_cmd_subst(rest, :unquoted)

      {:double_quoted, ?"} ->
        check_double_quoted_cmd_subst(rest, :unquoted)

      {:double_quoted, ?\\} ->
        # Skip escaped character
        case rest do
          <<_next::utf8, remaining::binary>> ->
            check_double_quoted_cmd_subst(remaining, :double_quoted)

          "" ->
            false
        end

      {:double_quoted, ?$} ->
        case rest do
          # Found command substitution
          <<"(", _::binary>> -> true
          _ -> check_double_quoted_cmd_subst(rest, :double_quoted)
        end

      {:double_quoted, ?`} ->
        # Check for backtick command substitution
        case find_closing_backtick_simple(rest) do
          # Found backtick command substitution
          true -> true
          false -> check_double_quoted_cmd_subst(rest, :double_quoted)
        end

      {_, _} ->
        check_double_quoted_cmd_subst(rest, state)
    end
  end

  defp find_closing_backtick_simple(str) do
    String.contains?(str, "`")
  end

  defp extract_unquoted_parts("", acc, state, current) do
    # If we end in a quoted state, quotes are unbalanced
    case state do
      :single_quoted -> throw(:unbalanced_quotes)
      :double_quoted -> throw(:unbalanced_quotes)
      :unquoted -> if current != "", do: [current | acc], else: acc
    end
  end

  defp extract_unquoted_parts(<<char::utf8, rest::binary>>, acc, state, current) do
    case {state, char} do
      {:unquoted, ?'} ->
        new_acc = if current != "", do: [current | acc], else: acc
        extract_unquoted_parts(rest, new_acc, :single_quoted, "")

      {:unquoted, ?"} ->
        new_acc = if current != "", do: [current | acc], else: acc
        extract_unquoted_parts(rest, new_acc, :double_quoted, "")

      {:single_quoted, ?'} ->
        extract_unquoted_parts(rest, acc, :unquoted, "")

      {:double_quoted, ?"} ->
        extract_unquoted_parts(rest, acc, :unquoted, "")

      {:double_quoted, ?\\} ->
        # Skip escaped char in double quotes
        case rest do
          <<_next::utf8, remaining::binary>> ->
            extract_unquoted_parts(remaining, acc, :double_quoted, current)

          "" ->
            extract_unquoted_parts("", acc, :double_quoted, current)
        end

      {:unquoted, _} ->
        extract_unquoted_parts(rest, acc, state, current <> <<char::utf8>>)

      {_, _} ->
        # In quoted context, ignore the character
        extract_unquoted_parts(rest, acc, state, current)
    end
  end

  defp contains_dangerous_unquoted_pattern?(part) do
    # Check for dangerous shell patterns in unquoted text using regex
    Regex.match?(~r/\||&&|\|\||;|>|<|`|\$\(|(?<!\&)\&(?!\&)|<\(|>\(/, part)
  end
end
