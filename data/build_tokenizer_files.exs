#!/usr/bin/env elixir

"data/o200k_base.tiktoken"
|> File.stream!([], :line)
|> Enum.reduce({%{}, []}, fn line, {vocab_acc, merges_acc} ->
  line = String.trim(line)
  [token, id_or_rank] = String.split(line, " ")

  case Integer.parse(id_or_rank) do
    # If it's an integer, it's a vocab entry
    {id, ""} ->
      token_decoded = Base.decode64!(token)
      {Map.put(vocab_acc, token_decoded, id), merges_acc}

    # If it's not, treat it as a merge pair
    _ ->
      merge_pair = String.split(token, ",") |> List.to_tuple()
      {vocab_acc, [{merge_pair, String.to_integer(id_or_rank)} | merges_acc]}
  end
end)
|> then(fn {vocab, merges} ->
  merges =
    merges
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()

  reverse_vocab = Map.new(vocab, fn {key, value} -> {value, key} end)

  File.write!("data/o200k_base.merges", :erlang.term_to_binary(merges))
  File.write!("data/o200k_base.vocab", :erlang.term_to_binary(vocab))
  File.write!("data/o200k_base.reverse_vocab", :erlang.term_to_binary(reverse_vocab))
end)
