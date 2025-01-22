defmodule AI.Tokenizer.Tokens_cl100k_base do
  @moduledoc """
  This module implements the cl100k-base tokenizer model used by OpenAI's
  `text-embedding-3-large` model.
  """

  @merges :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.merges"))
  @vocab :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.vocab"))
  @reverse_vocab :erlang.binary_to_term(File.read!("data/tokens/cl100k_base.reverse_vocab"))

  @special_tokens %{
    "<|endoftext|>" => 100_257,
    "<|fim_prefix|>" => 100_258,
    "<|fim_middle|>" => 100_259,
    "<|fim_suffix|>" => 100_260,
    "<|endofprompt|>" => 100_276
  }

  # Source: https://github.com/openai/tiktoken/blob/main/tiktoken_ext/openai_public.py
  @pattern ~r<
    (?i:[sdmt]|ll|ve|re)
  | [^\r\n\p{L}\p{N}]?+\p{L}++
  | \p{N}{1,3}+
  | \s?[^\s\p{L}\p{N}]++[\r\n]*+
  | \s++$
  | \s*[\r\n]
  | \s+(?!\S)
  | \s
  >xu

  def get_merges(), do: @merges
  def get_vocab(), do: @vocab
  def get_reverse_vocab(), do: @reverse_vocab
  def get_special_tokens(), do: @special_tokens
  def get_pattern(), do: @pattern
end
