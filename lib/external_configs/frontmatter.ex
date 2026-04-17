defmodule ExternalConfigs.Frontmatter do
  @moduledoc """
  Parses YAML frontmatter out of markdown-like documents.

  Supported input:

      ---
      key: value
      other: [a, b]
      ---
      Body markdown goes here.

  Returns `{:ok, %{frontmatter: map(), body: binary()}}` on success. Inputs
  that do not contain a complete `---` ... `---` block (no opener, or an
  opener without a closer) are returned as body with an empty frontmatter
  map. The original content is preserved verbatim so callers can still
  display or re-parse it.
  """

  @type parsed :: %{frontmatter: map(), body: binary()}

  @spec parse(binary()) :: {:ok, parsed} | {:error, term()}
  def parse(content) when is_binary(content) do
    case split(content) do
      {:no_frontmatter, body} ->
        {:ok, %{frontmatter: %{}, body: body}}

      {:ok, yaml, body} ->
        case decode_yaml(yaml) do
          {:ok, map} -> {:ok, %{frontmatter: map, body: body}}
          {:error, reason} -> {:error, {:invalid_yaml, reason}}
        end
    end
  end

  # Splits the input into (yaml, body). Recognizes a leading `---` fence
  # (optionally preceded by a UTF-8 BOM and/or blank lines) and the closing
  # `---` fence that terminates the frontmatter block.
  @spec split(binary()) ::
          {:ok, binary(), binary()} | {:no_frontmatter, binary()}
  defp split(content) do
    stripped = strip_bom(content)

    case String.split(stripped, ~r/\r?\n/, parts: 2) do
      [first, rest] ->
        if fence?(first) do
          case split_body(rest) do
            {:ok, yaml, body} -> {:ok, yaml, body}
            :no_close -> {:no_frontmatter, content}
          end
        else
          {:no_frontmatter, content}
        end

      _ ->
        {:no_frontmatter, content}
    end
  end

  defp fence?(line), do: String.trim(line) == "---"

  defp split_body(rest) do
    lines = String.split(rest, ~r/\r?\n/)
    do_split_body(lines, [])
  end

  defp do_split_body([], _acc), do: :no_close

  defp do_split_body([line | tail], acc) do
    if fence?(line) do
      yaml = acc |> Enum.reverse() |> Enum.join("\n")
      body = Enum.join(tail, "\n")
      {:ok, yaml, body}
    else
      do_split_body(tail, [line | acc])
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(other), do: other

  defp decode_yaml("") do
    {:ok, %{}}
  end

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      # Empty YAML documents can decode to nil; treat that as empty frontmatter.
      {:ok, nil} -> {:ok, %{}}
      {:ok, other} -> {:error, {:not_a_mapping, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
