defmodule Skills.Toml do
  @moduledoc """
  Encode a skill definition as TOML.

  Skills are stored as TOML files so they are easy to create and edit by hand.

  This module intentionally implements only the subset of TOML we need for the
  skill schema:
  - strings
  - string arrays
  - a shallow `response_format` table (string/number/bool values)

  If we need richer encoding later, we can expand this module or swap it for a
  dedicated encoder.
  """

  @type encode_error ::
          {:invalid_response_format_value, key :: String.t(), term()}
          | {:invalid_response_format_key, term()}

  @doc """
  Encode a `%Skills.Skill{}` to a TOML string.

  The output is stable (fixed key order) to minimize noisy diffs.
  """
  @spec encode_skill(Skills.Skill.t()) :: {:ok, String.t()} | {:error, encode_error}
  def encode_skill(%Skills.Skill{} = skill) do
    with {:ok, rf_section} <- response_format_section(skill.response_format) do
      toml =
        [
          kv_string("name", skill.name),
          kv_string("description", skill.description),
          kv_string("model", skill.model),
          kv_string_array("tools", skill.tools),
          kv_multiline_string("system_prompt", skill.system_prompt),
          rf_section
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      {:ok, toml}
    end
  end

  defp response_format_section(nil), do: {:ok, ""}

  defp response_format_section(%{} = map) do
    map
    |> normalize_keys()
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      case {k, v} do
        {key, _} when not is_binary(key) ->
          {:halt, {:error, {:invalid_response_format_key, key}}}

        {key, value} ->
          case encode_value(value) do
            {:ok, encoded} -> {:cont, {:ok, ["#{key} = #{encoded}" | acc]}}
            {:error, _} -> {:halt, {:error, {:invalid_response_format_value, key, value}}}
          end
      end
    end)
    |> case do
      {:ok, lines} ->
        lines = Enum.reverse(lines)

        {:ok,
         [
           "",
           "[response_format]",
           Enum.join(lines, "\n")
         ]
         |> Enum.join("\n")}

      {:error, _} = err ->
        err
    end
  end

  defp response_format_section(other),
    do: {:error, {:invalid_response_format_value, "response_format", other}}

  defp normalize_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp encode_value(value) when is_binary(value), do: {:ok, encode_string(value)}
  defp encode_value(value) when is_boolean(value), do: {:ok, if(value, do: "true", else: "false")}
  defp encode_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp encode_value(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp encode_value(_), do: {:error, :unsupported}

  defp kv_string(key, value) do
    "#{key} = #{encode_string(value)}"
  end

  defp kv_string_array(key, values) when is_list(values) do
    encoded =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&encode_string/1)
      |> Enum.join(", ")

    "#{key} = [#{encoded}]"
  end

  defp kv_multiline_string(key, value) do
    "#{key} = \"\"\"\n#{escape_triple_quotes(value)}\n\"\"\""
  end

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  defp escape_triple_quotes(value) do
    String.replace(value, "\"\"\"", "\\\"\\\"\\\"")
  end
end
