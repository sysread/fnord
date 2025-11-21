defmodule AI.Tools.File.Edit.WhitespaceFitter do
  @moduledoc """
  Deterministic, language-agnostic whitespace fitting for file hunks.

  This module is intentionally **not** wired into `AI.Tools.File.Edit` yet.
  It exists as a proof-of-concept for how we might:

    * Infer indentation style (tabs vs spaces, indent width) from local context
    * Re-base a replacement hunk's indentation to match the original region
    * Prepare `new_hunk_fitted` that can be spliced in literally

  The goal is to make fuzzy / whitespace-tolerant matching safer by
  ensuring that once we have found the right region, we can adjust the
  replacement's indentation to dovetail with the surrounding code
  without relying on language-specific formatters or additional LLM
  calls.
  """

  @tab_width 4

  @type indent_style :: %{type: :spaces | :tabs, width: pos_integer}

  @doc """
  Infer indentation style (tabs vs spaces, and space width) from a list of lines.

  This looks only at leading whitespace on non-empty lines. If it sees any
  leading tabs and no spaced indentation, it assumes a tab-indented style.
  Otherwise, it looks at the distribution of leading space counts and picks a
  representative width (e.g., 2 or 4).

  If there is not enough information, it falls back to `%{type: :spaces, width: 2}`.
  """
  @spec infer_indent_style([String.t()]) :: indent_style
  def infer_indent_style(lines) when is_list(lines) do
    stats =
      Enum.reduce(lines, %{tabs: 0, space_counts: []}, fn line, acc ->
        case leading_ws_info(line) do
          {:tabs, n} when n > 0 -> %{acc | tabs: acc.tabs + n}
          {:spaces, n} when n > 0 -> %{acc | space_counts: [n | acc.space_counts]}
          _ -> acc
        end
      end)

    # Determine total visual columns for tabs vs spaces to pick dominant style
    total_space_cols = Enum.sum(stats.space_counts)
    total_tab_cols = stats.tabs * @tab_width

    cond do
      # Only tabs present
      stats.tabs > 0 and stats.space_counts == [] ->
        %{type: :tabs, width: 1}

      # Both tabs and spaces: choose based on total visual width
      stats.tabs > 0 and stats.space_counts != [] and total_tab_cols > total_space_cols ->
        %{type: :tabs, width: 1}

      # Spaces present (dominant or tie)
      stats.space_counts != [] ->
        %{type: :spaces, width: pick_space_width(stats.space_counts)}

      # Fallback: no indentation info
      true ->
        # Degenerate case: no useful indentation; default to 2 spaces
        %{type: :spaces, width: 2}
    end
  end

  @doc """
  Fit a replacement hunk's indentation to match local context.

  Inputs:
    * `context_before` - lines before the original hunk (nearest first preferred)
    * `orig_hunk` - the original lines in the region being replaced
    * `context_after` - lines after the original hunk
    * `new_hunk_raw` - the proposed replacement text (may have arbitrary indentation)

  Output:
    * A single string containing `new_hunk_raw` with indentation adjusted to
      match the inferred style and depth of the original region.

  Behavior (high level):
    * Infer indentation style from `context_before ++ orig_hunk ++ context_after`.
    * Determine the target base indentation for the region using the original
      hunk, falling back to neighbors if needed.
    * Compute relative indentation within `new_hunk_raw` and re-base it at the
      target depth, preserving the replacement's internal structure.

  This function is deliberately conservative: it only changes *leading*
  whitespace and leaves the rest of each line untouched.
  """
  @spec fit([String.t()], [String.t()], [String.t()], String.t()) :: String.t()
  def fit(context_before, orig_hunk, context_after, new_hunk_raw)
      when is_list(context_before) and is_list(orig_hunk) and is_list(context_after) and
             is_binary(new_hunk_raw) do
    style = infer_indent_style(context_before ++ orig_hunk ++ context_after)

    orig_infos = analyze_lines(orig_hunk)
    new_infos = analyze_lines(String.split(new_hunk_raw, "\n", trim: false))

    above_line = context_before |> Enum.reverse() |> Enum.find(&(&1 != ""))
    below_line = Enum.find(context_after, &(&1 != ""))

    base_target = base_target_indent(orig_infos, above_line, below_line)

    base_new =
      new_infos
      |> Enum.find(&(&1.content != ""))
      |> case do
        nil -> 0
        info -> info.indent_cols
      end

    new_infos
    |> Enum.map(fn %{indent_cols: ic, content: content} ->
      cond do
        content == "" ->
          ""
        true ->
          delta = ic - base_new
          target_cols = max(base_target + delta, 0)
          indent =
            case style.type do
              :spaces ->
                String.duplicate(" ", target_cols)
              :tabs ->
                level = indent_level(target_cols, style)
                indent_string(level, style)
            end
          indent <> content
      end
    end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  @type line_info :: %{indent_cols: non_neg_integer, content: String.t(), raw: String.t()}

  @spec analyze_lines([String.t()]) :: [line_info]
  defp analyze_lines(lines) when is_list(lines) do
    Enum.map(lines, &analyze_line/1)
  end

  @spec analyze_line(String.t()) :: line_info
  defp analyze_line(line) when is_binary(line) do
    {ws, content} = split_leading_ws(line)

    %{
      indent_cols: visual_width(ws),
      content: content,
      raw: line
    }
  end

  @spec split_leading_ws(String.t()) :: {String.t(), String.t()}
  defp split_leading_ws(line) do
    {ws_graphemes, rest} =
      line
      |> String.graphemes()
      |> Enum.split_while(&(&1 in [" ", "\t"]))

    {Enum.join(ws_graphemes), Enum.join(rest)}
  end

  @spec leading_ws_info(String.t()) ::
          {:tabs, non_neg_integer} | {:spaces, non_neg_integer} | :none
  defp leading_ws_info(line) do
    {ws, _} = split_leading_ws(line)

    cond do
      ws == "" ->
        :none

      String.trim_leading(ws, "\t") == "" ->
        {:tabs, String.length(ws)}

      String.trim_leading(ws, " ") == "" ->
        {:spaces, String.length(ws)}

      true ->
        :none
    end
  end

  @spec visual_width(String.t()) :: non_neg_integer
  defp visual_width(ws) do
    ws
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "\t", acc -> acc + @tab_width
      " ", acc -> acc + 1
      _, acc -> acc
    end)
  end

  @spec pick_space_width([non_neg_integer]) :: pos_integer
  defp pick_space_width([]), do: 2

  defp pick_space_width(counts) do
    counts
    |> Enum.filter(&(&1 > 0))
    |> case do
      [] ->
        2

      xs ->
        xs
        |> Enum.frequencies()
        |> Enum.max_by(&elem(&1, 1))
        |> elem(0)
        |> max(1)
    end
  end

  @spec base_target_indent([line_info], String.t() | nil, String.t() | nil) :: non_neg_integer
  defp base_target_indent(orig_infos, above_line, below_line) do
    orig_first = Enum.find(orig_infos, &(&1.content != ""))

    indent_above =
      case above_line do
        nil -> 0
        line -> analyze_line(line).indent_cols
      end

    indent_below =
      case below_line do
        nil -> indent_above
        line -> analyze_line(line).indent_cols
      end

    cond do
      orig_first != nil ->
        orig_first.indent_cols

      indent_below > indent_above ->
        indent_below

      true ->
        indent_above
    end
  end

  @spec indent_level(non_neg_integer, indent_style) :: non_neg_integer
  defp indent_level(cols, %{type: :tabs}) do
    # Convert from visual columns back to a logical tab count. We currently
    # treat each tab as @tab_width visual columns in visual_width/1.
    div(cols + @tab_width - 1, @tab_width)
  end

  defp indent_level(cols, %{type: :spaces, width: w}) when w > 0 do
    div(cols + w - 1, w)
  end

  @spec indent_string(non_neg_integer, indent_style) :: String.t()
  defp indent_string(level, %{type: :tabs}) when level >= 0 do
    String.duplicate("\t", level)
  end

  defp indent_string(level, %{type: :spaces, width: w}) when level >= 0 do
    String.duplicate(" ", level * w)
  end
end
