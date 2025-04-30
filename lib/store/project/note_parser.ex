defmodule Store.Project.NoteParser do
  @moduledoc """
  This module is deprecated. It remains to support `Store.Project.Note`.
  """

  @re_topic ~r/
    ^
    \s*
    {
    \s*
    topic
    \s+
    (?<topic>
        (?: " (?: [^"] | \\")* ")
      | (?: [^{}]+)
    )
    \s*
    (?<facts>.*)
    $
  /x

  @re_fact ~r/
    {
    \s*
    fact
    \s+
    (?<fact>
        (?: " (?: [^"] | \\")* ")
      | (?: [^{}]+)
    )
  /x

  @re_string ~r/
    \s*
    (?:
        (?: " (?<quoted> (?: [^"] | \\")*) ")
      | (?<bare>   [^{}]+)
    )
    \s*
  /x

  @spec parse(binary) :: {:ok, {String.t(), [String.t()]}} | {:error, atom, atom}
  def parse(input) do
    if is_binary(input) do
      with {:ok, topic, facts_string} <- parse_topic(input),
           {:ok, facts} <- parse_facts(facts_string) do
        {:ok, {topic, facts}}
      end
    else
      {:error, :invalid_format, :input}
    end
  end

  defp parse_topic(input) do
    with %{"topic" => topic, "facts" => facts} <- Regex.named_captures(@re_topic, input),
         {:ok, content} <- parse_string(topic) do
      {:ok, content, String.trim(facts)}
    else
      _ -> {:error, :invalid_format, :topic}
    end
  end

  defp parse_facts(input) do
    Regex.scan(@re_fact, input, capture: :all_but_first)
    |> case do
      [] ->
        {:error, :invalid_format, :facts}

      facts ->
        facts
        |> Enum.reduce_while([], fn [fact], acc ->
          case parse_string(fact) do
            {:ok, content} -> {:cont, [content | acc]}
            _ -> {:halt, {:error, :invalid_format, :fact}}
          end
        end)
        |> then(fn facts -> {:ok, facts |> Enum.reverse()} end)
    end
  end

  defp parse_string(input) do
    input = String.trim(input)

    Regex.named_captures(@re_string, input)
    |> case do
      %{"quoted" => quoted, "bare" => ""} -> {:ok, quoted}
      %{"quoted" => "", "bare" => bare} -> {:ok, bare}
      _ -> {:error, :invalid_format, :string}
    end
  end
end
