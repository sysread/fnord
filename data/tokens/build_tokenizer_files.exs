#!/usr/bin/env elixir

defmodule BuildTokenizerFiles do
  @moduledoc false

  def main(encoding) do
    path = "data/tokens/#{encoding}.tiktoken"

    # Load every line as a merge (BASE64 bytes + rank)
    merges_with_rank =
      File.stream!(path, [], :line)
      |> Enum.map(fn line ->
        [b64, rank_str] = String.split(String.trim(line), " ")
        {Base.decode64!(b64), String.to_integer(rank_str)}
      end)

    # Sort by rank ascending, assign IDs from 256 upward
    merges =
      merges_with_rank
      |> Enum.sort_by(fn {_bytes, rank} -> rank end)

    # Build initial vocab for single-byte tokens
    initial_vocab =
      for i <- 0..255, into: %{} do
        {<<i>>, i}
      end

    # Add merged byte-sequences to vocab
    vocab =
      Enum.reduce(merges, initial_vocab, fn {bytes, id}, acc ->
        Map.put(acc, bytes, id)
      end)

    # Add special tokens at fixed IDs
    special_tokens = %{
      "<|endoftext|>" => 100_257,
      "<|fim_prefix|>" => 100_258,
      "<|fim_middle|>" => 100_259,
      "<|fim_suffix|>" => 100_260,
      "<|endofprompt|>" => 100_276
    }

    vocab = Map.merge(vocab, special_tokens)

    # Build reverse vocab
    reverse_vocab =
      for {token, id} <- vocab, into: %{} do
        {id, token}
      end

    # Persist to disk
    File.write!("data/tokens/#{encoding}.merges", :erlang.term_to_binary(merges))
    File.write!("data/tokens/#{encoding}.vocab", :erlang.term_to_binary(vocab))
    File.write!("data/tokens/#{encoding}.reverse_vocab", :erlang.term_to_binary(reverse_vocab))
  end
end

# Generate files for supported encodings
BuildTokenizerFiles.main("o200k_base")
BuildTokenizerFiles.main("cl100k_base")
