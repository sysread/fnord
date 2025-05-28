defmodule AI.Tokenizer.Tokens_cl100k_base do
  @moduledoc """
  This module implements the cl100k-base tokenizer model used by OpenAI's
  `text-embedding-3-large` model.
  """

  @merges_list :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.merges"))
  @vocab :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.vocab"))
  @reverse_vocab :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.reverse_vocab"))
  @merge_ranks Enum.with_index(@merges_list) |> Map.new(fn {bytes, idx} -> {bytes, idx} end)

  @special_tokens %{
    "<|endoftext|>" => 100_257,
    "<|fim_prefix|>" => 100_258,
    "<|fim_middle|>" => 100_259,
    "<|fim_suffix|>" => 100_260,
    "<|endofprompt|>" => 100_276
  }

  # Source: https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py
  @pattern ~r<
    '(?i:[sdmt]|ll|ve|re)         # contractions
  | [^\r\n\p{L}\p{N}]?\p{L}+       # words (opt prefix + letters)
  | \p{N}{1,3}                     # 1–3 digits
  | [ ]?[^\s\p{L}\p{N}]+[\r\n]*    # punctuation/symbols (opt space, then run, then newlines)
  | \s+$                           # whitespace to end
  | \s*[\r\n]                      # any preceding spaces + newline
  | \s+(?!\S)                      # whitespace not followed by non-space
  | \s                             # any single whitespace
  >xu

  def get_merges(), do: @merges_list
  def get_merge_ranks(), do: @merge_ranks
  def get_vocab(), do: @vocab
  def get_reverse_vocab(), do: @reverse_vocab
  def get_special_tokens(), do: @special_tokens
  def get_pattern(), do: @pattern
end
